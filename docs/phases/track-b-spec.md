# Track B Engineering Specification — Concurrency, Security, Backups & CI (`v0.1.0` Release Gate)

- **Date:** 2026-11-27
- **Author:** Gemini (Architect), for Claude (Developer) & Justin (Product Owner)
- **Parent Plan:** [`docs/phases/phase-02-hardening-and-forecasting.md`](phase-02-hardening-and-forecasting.md) (Track B: Steps 7–9, 11–12)
- **Companion Audit:** [`docs/reviews/2026-11-27-post-track-a-audit.md`](../reviews/2026-11-27-post-track-a-audit.md)

> **Purpose:** Turnkey engineering blueprint for Track B so implementation requires zero exploratory design. Completing this spec (alongside the `AUDIT-01..04` tickets from the Post-Track-A Audit) is the **exit gate for tagging `v0.1.0`**.

---

## 1. SQLite Concurrency, Pool Sizing & Write-Serialization

### 1.1 Why Current Code Can Hit `SQLITE_BUSY` & Torn Reads

1. **PRAGMA ordering race (`src/Db/Pool.hs:44-50`):** `openConfigured` runs `PRAGMA journal_mode = WAL` *before* `PRAGMA busy_timeout = 5000`, and repeats `journal_mode = WAL` on every newly opened pooled connection. If connection #2 opens while connection #1 holds a write lock, `journal_mode = WAL` executes with `busy_timeout = 0` and immediately throws `SQLITE_BUSY`.
2. **Deferred lock-upgrade deadlock (`sqlite-simple`'s `withTransaction`):** `withTransaction` issues `BEGIN` (`BEGIN DEFERRED`). When two pooled connections enter `withTransaction`, read a row, and then attempt `INSERT`/`UPDATE`/`DELETE`, SQLite **cannot** wait for `busy_timeout` (doing so would deadlock two snapshot readers waiting to become the sole writer) and fails **immediately** with `SQLITE_BUSY`.
3. **Multi-checkout torn reads & TOCTOU (`src/Api/*`, `src/Db/Transaction.hs`):**
   - `Api.Budget.renderFragment` checks out a pool connection **5 separate times** per render (`listAccounts`, `listCategoryGroups`, `listCategories`, `listAllAssignments`, `listAllTransactions`) with no shared snapshot.
   - `Db.Transaction.insertSpending`, `insertTransfer`, `updateSpending`, `updateTransfer`, and `withReplaceable` run lookups (`requireAccount`, `getTransaction`) **outside** the SQLite transaction, enabling double-click edit duplication (`AUDIT-05`) and reconciliation races.
   - `listAllTransactions` / `listTransactionsInMonth` run **1 + N** queries (`fetchLines` per categorized transaction).

### 1.2 Connection Pool Sizing & Exact PRAGMA Sequence (`src/Db/Pool.hs`)

- **Pool configuration:** Max **`4` connections** (down from `8`), idle timeout `60` seconds. SQLite is single-writer regardless of pool size; 4 connections allow parallel HTMX fragment reads in WAL mode while keeping writer contention minimal.
- **Per-connection setup (`openConfigured`, wrapped in `bracketOnError (open dbPath) close`):**
  ```sql
  PRAGMA busy_timeout = 5000;      -- MUST BE FIRST on every connection
  PRAGMA foreign_keys = ON;        -- Per-connection in SQLite
  PRAGMA synchronous = NORMAL;     -- Crash-safe in WAL mode, ~5x faster fsyncs than FULL
  PRAGMA temp_store = MEMORY;      -- Keep temp B-trees in RAM
  ```
- **One-time startup initialization inside `createPool` (wrapped in `onException ... closePool`):**
  ```haskell
  createPool :: FilePath -> IO (Pool Connection)
  createPool dbPath = do
    createDirectoryIfMissing True (takeDirectory dbPath)
    pool <- newPool (defaultPoolConfig (openConfigured dbPath) close 60 4)
    (`onException` closePool pool) $ withResource pool $ \conn -> do
      -- journal_mode=WAL is persistent in the DB header; set once here, not per connection.
      _ <- query_ conn "PRAGMA journal_mode = WAL" :: IO [Only Text]
      execute_ conn "PRAGMA wal_autocheckpoint = 1000" -- ~4 MB WAL passive checkpoint target
      autoBackupBeforeMigrations conn dbPath            -- see §3.2
      runMigrations conn
    pure pool
  ```
- **Graceful shutdown & WAL truncation (`closePool` + `app/Main.hs`):**
  - In `closePool`: run a best-effort `withResource pool (\conn -> void (try @SQLError (execute_ conn "PRAGMA wal_checkpoint(TRUNCATE)")))` before `destroyAllResources pool` so `.db-wal` is folded cleanly back into `.db` on exit.
  - In `app/Main.hs`: wrap server execution in `bracket (createPool (configDbPath config)) closePool`.

### 1.3 Transaction Wrappers (`src/Db/Tx.hs` or `Db.Pool`)

Add two explicit transaction combinators and **ban bare `Database.SQLite.Simple.withTransaction` on write paths**:

```haskell
-- | Acquires SQLite's RESERVED write lock upfront. Unlike sqlite-simple's
-- 'withTransaction' (BEGIN DEFERRED), concurrent callers wait up to
-- busy_timeout (5000 ms) in FIFO/retry order instead of failing
-- immediately with SQLITE_BUSY on a read->write lock upgrade.
withImmediateTransaction :: Connection -> IO a -> IO a
withImmediateTransaction conn action = mask $ \restore -> do
  execute_ conn "BEGIN IMMEDIATE"
  result <- restore action `onException` ignoringExceptions (execute_ conn "ROLLBACK")
  execute_ conn "COMMIT"
  pure result

-- | Opens a consistent, point-in-time MVCC read snapshot across multiple
-- SELECT queries on the same Connection in WAL mode.
withReadSnapshot :: Connection -> IO a -> IO a
withReadSnapshot conn action = mask $ \restore -> do
  execute_ conn "BEGIN DEFERRED"
  result <- restore action `onException` ignoringExceptions (execute_ conn "ROLLBACK")
  execute_ conn "COMMIT"
  pure result

ignoringExceptions :: IO () -> IO ()
ignoringExceptions io = void (try @SomeException io)
```

### 1.4 Required Mutation & Query Refactors (`src/Db/Transaction.hs`, `src/Api/*`)

1. **Wrap every multi-step write in `withImmediateTransaction` with ALL precondition reads inside it:**
   - `insertSpending`: look up `accId` (returning `Left (AccountNotFound accId)` instead of throwing unexported `UnknownAccount`), verify `not (isArchived acc)` and `isOnBudget acc`, verify all `tlCategory` IDs exist and are active, then insert parent + lines — **all inside one `withImmediateTransaction`**.
   - `insertTransfer`: look up `fromAcc` and `toAcc`, verify `fromAccId /= toAccId`, `amount > zeroCents`, neither archived, and `sameBudgetStatus`, then insert `transfers` + both legs — **all inside one `withImmediateTransaction`**.
   - `withReplaceable` (`deleteTransaction`, `updateInflow`, `updateSpending`, `updateTransfer`): move `getTransaction` **inside** `withImmediateTransaction` (closing the double-click duplication race in `AUDIT-05`), verify **both** legs of a `TransferLeg` are non-`Reconciled` (`AUDIT-02`), preserve per-leg status on `updateTransfer`, verify matching `Categorization` kind on `update*`, and preserve `txImportHash` when `accId == txAccount tx` (`AUDIT-03`).
   - `reconcileAccount :: Connection -> AccountId -> Cents -> IO (Either DomainError Bool)`: move the `clearedBalance == statementBalance` check **inside** `withImmediateTransaction` so no concurrent `Cleared` row can slip in between reading and `UPDATE ... SET status = 'reconciled'`.
   - `setTransactionCleared`, `archiveAccount` (including zero-balance check), `archiveCategoryGroup` (including active-children check), `archiveCategory` (including zero-available check across `ym..end`), `applyMigration`: wrap in `withImmediateTransaction`.
2. **Collapse `Api.*` handlers to ONE `withConn` per HTTP request:**
   - Read-only handlers (`GET /budget`, `GET /accounts`, `GET /categories`, `GET /transactions`): `withConn $ \conn -> withReadSnapshot conn $ do ...`
   - Mutating handlers (`POST ...`): `withConn $ \conn -> do { writeResult <- ...; readState <- withReadSnapshot conn ...; pure html }` — maximum 1 pool checkout per HTTP request!
3. **Eliminate the N+1 `fetchLines` query (`src/Db/Transaction.hs`):**
   - Replace per-row `fetchLines` in `listTransactionsForAccount`, `listTransactionsInMonth`, and `listAllTransactions` with a single helper:
     - When `categorizedIds` is empty: skip querying `transaction_lines`.
     - For `listAllTransactions`: `SELECT transaction_id, category_id, amount FROM transaction_lines ORDER BY transaction_id, id` (1 query total for the entire table!), group into `Map TransactionId (NonEmpty TransactionLine)` via `Data.Map.Strict`, and assemble each `Categorized` `TransactionRow` in memory (`O(N log N)`).
     - Match `"categorized"` explicitly in `rowToTransaction` and throw exported `CorruptRow` on any unknown `trKind`.

---

## 2. Security & Threat Model (`v0.1.0` Exit Gate)

### 2.1 Threat Model Summary

Bucktracker runs unauthenticated on `127.0.0.1:<port>`. An attacker **cannot** reach the socket from the LAN, **but any website opened in the user's browser on the same machine can**:
1. **Forge cross-origin `POST` requests (CSRF)** to `http://127.0.0.1:8080/*` via auto-submitted HTML forms or `fetch(..., { mode: 'no-cors' })`.
2. **Perform DNS Rebinding** (resolving `attacker.example` to `127.0.0.1` after TTL expiry) to read `/budget`, `/accounts`, and `/transactions` with full Same-Origin privileges unless the `Host` header is checked.
3. **Inject malicious strings** via imported bank payees/remittance descriptions (Track C) into Lucid HTML or `@alpinejs/csp` directives unless CSP and template rules are airtight.
4. **Exhaust memory/CPU** via multi-megabyte form bodies or astronomical `?month=` parameters (`AUDIT-01`).

### 2.2 WAI Security Middleware Architecture (`src/Api/Middleware.hs`)

Wrap `Api.application` with a composable WAI middleware stack in `src/Api/Middleware.hs`:

```haskell
securityMiddleware :: SecurityConfig -> Middleware
securityMiddleware cfg =
    securityHeadersMiddleware
  . hostAllowlistMiddleware (secPort cfg)
  . bodyLimitMiddleware
  . csrfMiddleware (secCsrfToken cfg) (secPort cfg)
```

#### Layer A — `Host` Header Allowlist (DNS-Rebinding Defense)
- Inspect `requestHeaderHost req`.
- Allow **only**: `"localhost"`, `"127.0.0.1"`, `"localhost:" <> portBytes`, `"127.0.0.1:" <> portBytes` (case-insensitive on `"localhost"`, plus `Nothing` *only* if explicitly enabled in unit tests, though `hspec-wai` sends `"localhost"` or can set `Host`).
- Everything else → immediate `403 Forbidden` plain-text response before touching Servant or SQLite.

#### Layer B — Stateless Synchronizer / Double-Submit CSRF Strategy (HTMX + Plain HTML Forms)
Because Bucktracker is a single-user local process, **one cryptographically random 256-bit token generated at server boot** (stored in `AppEnv`, e.g., two concatenated `Data.UUID.V4.nextRandom` values — `uuid` is already in `package.yaml` and uses OS CSPRNG!) acts as both the cookie value and the synchronizer token, requiring **zero database tables and zero session state**:

1. **Cookie delivery on `GET` / `HEAD`:**
   - Set `Set-Cookie: bt_csrf=<token>; Path=/; HttpOnly; SameSite=Strict` on HTML responses whenever the request does not already present `Cookie: bt_csrf=<token>`.
   - `SameSite=Strict` prevents browsers from attaching `bt_csrf` on cross-site form navigations; `HttpOnly` prevents JS reading the cookie directly.
2. **Token embedding in HTML (`src/Api/Html.hs`):**
   - Thread `CsrfToken` into `Api.Html` (or pass via `Reader` / parameter):
     - In `page`'s `<head>`: render `<meta name="csrf-token" content="<token>">`.
     - In `/static/app.js`: add a 5-line `document.body.addEventListener('htmx:configRequest', (e) => { ... })` listener that reads `<meta name="csrf-token">` and sets `e.detail.headers['X-CSRF-Token'] = token` on every HTMX request automatically!
     - Provide `csrfInput :: CsrfToken -> Html ()` (`input_ [type_ "hidden", name_ "_csrf", value_ token]`) inside every `<form>` so **plain non-JS browser POSTs** submit `_csrf=<token>` in the `application/x-www-form-urlencoded` body without needing JS!
3. **Verification on unsafe methods (`POST`, `PUT`, `PATCH`, `DELETE`):**
   - **Step 1 (Fetch Metadata / Origin gate):**
     - If `Sec-Fetch-Site` header is present and its value is not `"same-origin"` or `"none"`, reject with `403 Forbidden`.
     - If `Origin` header is present and its value is not `"http://localhost:" <> port` or `"http://127.0.0.1:" <> port` (or portless in test harness), reject with `403 Forbidden`.
   - **Step 2 (Token match — constant-time comparison):**
     - Require `Cookie` header to contain `bt_csrf == expectedToken`.
     - Require **either**:
       - Header `X-CSRF-Token == expectedToken` (covers all HTMX requests in `O(1)` without re-parsing the body), **OR**
       - Form body parameter `_csrf == expectedToken` (covers progressive-enhancement non-JS `<form>` POSTs; note: buffer the bounded body chunks once and replay them via a `requestBody` `IORef` so Servant's `ReqBody '[FormUrlEncoded]` still reads the full stream!).
     - Mismatch or missing → `403 Forbidden`.

#### Layer C — Strict CSP & Security Response Headers
Attach to **every** HTTP response:
```http
Content-Security-Policy: default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; font-src 'self'; connect-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'
X-Content-Type-Options: nosniff
Referrer-Policy: no-referrer
X-Frame-Options: DENY
```

> **CRITICAL Pre-Requisites for `style-src 'self'` (Verified Against Vendored Assets):**
> 1. **Move `Api.Html.pageStyle` to `/static/app.css`:** Remove `style_ pageStyle` from `src/Api/Html.hs:46` and link `<link rel="stylesheet" href="/static/app.css">` instead — an inline `<style>` tag is blocked by `style-src 'self'`.
> 2. **Disable HTMX's inline indicator `<style>` injection:** Vendored `static/htmx.min.js` defaults to `includeIndicatorStyles: true`, which injects an inline `<style>` element into `<head>` on boot and triggers a CSP violation! Add `<meta name="htmx-config" content='{"includeIndicatorStyles":false}'>` to `Api.Html.page` and place `.htmx-indicator { opacity: 0; } .htmx-request .htmx-indicator, .htmx-request.htmx-indicator { opacity: 1; transition: opacity 200ms ease-in; }` inside `/static/app.css`.
> 3. **Alpine `x-show` works out of the box:** Verified in `static/alpine-csp.min.js` — `x-show` uses CSSOM `el.style.setProperty("display", "none")`, which CSP Level 3 permits under `style-src 'self'`. Add `[x-cloak] { display: none !important; }` to `/static/app.css` and `x-cloak` on hidden inline inputs to prevent pre-init flash.
> 4. **Eliminate dynamic `x-data` string interpolation (`AUDIT-06`):** Change `Api.Budget.assignedCell` from `xData_ ("inlineAssign('" <> displayText <> "')")` to `xData_ "inlineAssign()"` + `data-initial-value` (`this.$el.dataset.initialValue`), matching `reconcileCalc`. **Hard rule:** Never interpolate dynamic strings into any `x-*` attribute.

#### Layer D — Request Body & Domain Input Bounds
- **HTTP body limit (`bodyLimitMiddleware`):**
  - Default max request body: **65,536 bytes (64 KB)** on all routes (`413 Payload Too Large` if exceeded, enforced *while streaming chunks* via `getRequestBodyChunk`, not after allocating `strictRequestBody`!).
  - Route exception for Track C: allow **10,485,760 bytes (10 MB)** exclusively on `POST /import/preview`.
- **Domain & API bounds (`Domain.Validation`, `Domain.Types`, `Api.Transactions`, `Config`):**
  - `nonEmptyName`: `let stripped = Text.strip raw` → reject empty (`EmptyName`), reject `Text.any isControl stripped` (`InvalidCharacters`), reject `Text.length stripped > 80` (`NameTooLong kind 80`), and return `Right stripped`!
  - `validatePayee`: strip surrounding whitespace, reject control chars, cap at `160` characters (`NameTooLong "payee" 160`; allow empty or normalize as decided — recommend non-empty or trimmed `<= 160`).
  - `NewSpendingForm`: cap split lines at `50` (`TooManySplitLines`), and reject if `length lineCategoryIds /= length lineAmounts` (`AUDIT-03`).
  - `mkYearMonth`: require `1900 <= y && y <= 2200` (`InvalidYear y`) — closes the 1.2-billion-month OOM / `maxBound` infinite loop (`AUDIT-01`)!
  - `mkTransferPair` / `Db.insertTransfer` / `Db.updateTransfer`: reject `amount <= zeroCents` (`TransferAmountMustBePositive`) in `Domain` and `Db`, not just `Api`.
  - `Config.hs`: validate `1 <= configPort <= 65535` and `nonempty` `BUCKTRACKER_DB_PATH`.

---

## 3. Automated Backups & Integrity Checks (`src/Db/Backup.hs`, CLI & UI)

### 3.1 `VACUUM INTO` vs. Online Backup API — Architectural Choice

SQLite offers two consistent live-backup mechanisms:
- `VACUUM INTO 'path'` rebuilds and compacts the entire database into a fresh file in one SQL statement, but cannot overwrite an existing file and holds a read transaction for the full rebuild.
- **SQLite Online Backup API (`Database.SQLite3.backupInit` / `backupStep`)** — already wired in `src/Db/Backup.hs` via `direct-sqlite` — copies page-by-page, yields cleanly to concurrent writers between chunks, and copies exact page state fast.

**Decision:** Keep `Db.Backup`'s Online Backup API, harden its chunking/atomicity, and pair every backup with **`PRAGMA integrity_check`**.

### 3.2 Hardened `src/Db/Backup.hs` Specification

```haskell
module Db.Backup
  ( BackupError (..)
  , backupTo
  , createTimestampedBackup
  , checkIntegrity
  ) where
```

1. **`backupTo :: Connection -> FilePath -> FilePath -> IO (Either BackupError ())`** (takes `sourceDbPath` and `destPath`):
   - **Self-overwrite guard:** Canonicalize parent directories + filenames (`canonicalizePath` on existing dirs + `normalise`); if `dest == source` (when `source /= ":memory:"`), return `Left BackupDestinationMatchesSource`.
   - **Directory prep & atomic `.tmp` target:** `createDirectoryIfMissing True (takeDirectory destPath)`. Write into `let tmpPath = destPath <.> "tmp"` (removing any stale `tmpPath` first), and wrap in `onException ... (ignoringExceptions (removeFile tmpPath))`.
   - **Chunked stepping (`100` pages per step):**
     - Call `Raw.backupStep backup 100`.
     - On `Raw.BackupDone`: finish backup, close `dest` handle, run `checkIntegrityFile tmpPath` (opening `tmpPath` and verifying `PRAGMA integrity_check(10)` returns `["ok"]`!), and only then `renameFile tmpPath destPath`!
     - On `Raw.BackupOK`: `threadDelay 10000` (10 ms yield so active HTMX writers are never starved) and recurse.
     - Catch `Raw.SQLError` with `ErrorBusy` / `ErrorLocked` during `backupStep`, sleep `50 ms` (up to e.g. 100 retries = 5 s), and retry.
2. **`checkIntegrity :: Connection -> IO (Either [Text] ())`:**
   - Execute `query_ conn "PRAGMA integrity_check(10)" :: IO [Only Text]`.
   - Return `Right ()` iff the result is `[Only "ok"]`; otherwise return `Left reasons`.
3. **Three Concrete Wiring Points Before `v0.1.0`:**
   - **Auto-backup before migrations (`Db.Pool.createPool`):** If `dbPath /= ":memory:"`, `doesFileExist dbPath` is `True`, `getFileSize dbPath > 0`, and `hasPendingMigrations conn` is `True`, automatically create `<takeDirectory dbPath>/backups/pre-migration-<YYYYMMDD-HHMMSS>.db` before running `runMigrations`! Prune `pre-migration-*.db` files beyond the newest `10`.
   - **CLI Subcommands (`app/Main.hs` via `System.Environment.getArgs`):**
     - `(no args)` → start Warp server as today.
     - `["--integrity-check"]` → open configured DB read-only/via `openConfigured`, run `checkIntegrity`, print `"bucktracker: integrity_check OK"` (`exitSuccess`) or print errors to `stderr` (`exitFailure`).
     - `["--backup"]` or `["--backup", customDest]` → open configured DB, run `backupTo` (defaulting to `<dbDir>/backups/manual-<YYYYMMDD-HHMMSS>.db`), verify integrity, print path, exit `0`.
   - **Web UI Trigger (`POST /accounts/backup` or `/system/backup` on `/accounts`):**
     - Zero user-supplied path parameters (eliminating path traversal by construction!).
     - Writes `<dbDir>/backups/bucktracker-<YYYYMMDD-HHMMSS>.db`, runs `checkIntegrity` on it, prunes manual UI backups beyond e.g. newest `20`, and renders a `successBanner`: `"Backup created and verified: bucktracker-20261127-161500.db"`.

---

## 4. Zero-Warning Build Pre-Flight & GitHub Actions CI

### 4.1 `-Werror` Pre-Flight Checklist (`package.yaml` & `src/Db/*`)

Before enabling `--ghc-options=-Werror` in CI, eliminate every current warning:
1. **`-Wunused-packages` in `package.yaml`:**
   - Move `text` and `time` out of top-level `dependencies:` into `library` and `tests` (since `app/Main.hs` imports neither).
   - Remove `aeson`, `transformers`, and `warp` from `library.dependencies` (`warp` stays in `bucktracker-exe`; keep `uuid` in `library` once §2.2 uses `Data.UUID.V4` for CSRF token generation, and add `wai-app-static`, `http-types`, `cookie` or header parsing as actually imported).
2. **`-Worphans` in `src/Db/*`:**
   - Add `{-# OPTIONS_GHC -Wno-orphans #-}` at the top of `src/Db/Field.hs` (whose module Haddock already documents why centralizing `FromField`/`ToField` bridge instances there is deliberate).
   - In `Db.Account`, `Db.Category`, and `Db.Assignment`, either define private row types (`AccountRow`, `CategoryGroupRow`, `CategoryRow`, `AssignmentRow` — matching `Db.Transaction.TransactionRow`!) or add explicit `{-# OPTIONS_GHC -Wno-orphans #-}` so zero warnings fire under `-Wall`.
3. **Test harness resource cleanup (`test/Api/Setup.hs`):**
   - Switch `Api.Setup` from `Test.Hspec.Wai.with` (which leaks open SQLite pools and temp files on Windows) to `around` with `bracket` closing the pool (`closePool`) and removing the temp directory after every test, and expose a CSRF-aware `postForm` helper so existing `Api.*Spec` tests pass seamlessly with CSRF middleware enabled.

### 4.2 Ready-to-Drop `.github/workflows/ci.yml`

Save verbatim at `.github/workflows/ci.yml`:

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

concurrency:
  group: ci-${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  lint:
    name: HLint
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Run HLint
        uses: haskell-actions/hlint-scan@v2
        with:
          path: "src/ app/ test/"

  build-and-test:
    name: Build & Test (${{ matrix.os }})
    runs-on: ${{ matrix.os }}
    strategy:
      fail-fast: false
      matrix:
        os: [ubuntu-latest, windows-latest]
    env:
      STACK_ROOT: ${{ runner.os == 'Windows' && 'C:\sr' || '/home/runner/.stack' }}
    steps:
      - uses: actions/checkout@v4

      - name: Cache Stack root & snapshot dependencies
        uses: actions/cache@v4
        with:
          path: |
            ${{ env.STACK_ROOT }}
            .stack-work
          key: stack-${{ runner.os }}-${{ hashFiles('stack.yaml', 'stack.yaml.lock', 'package.yaml') }}
          restore-keys: |
            stack-${{ runner.os }}-

      - name: Build and run test suite (-Werror)
        run: stack test --fast --ghc-options="-Werror" --test-arguments="--format=progress"

      - name: Verify CLI integrity-check flag on fresh DB
        shell: bash
        run: |
          TMP_DB="$(mktemp -u).db"
          BUCKTRACKER_DB_PATH="$TMP_DB" stack exec bucktracker-exe -- --integrity-check
          rm -f "$TMP_DB" "$TMP_DB-wal" "$TMP_DB-shm"
```
