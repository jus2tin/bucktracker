# Phase 2 Plan — Frontend & UX Foundation, Hardening, Bank Import & Forecasting

- **Date:** 2026-11-27
- **Author:** Gemini (Architect), for Justin (Product Owner) & Claude (Developer)
- **Prerequisite Review:** [`docs/reviews/2026-11-27-mvp-adversarial-review.md`](../reviews/2026-11-27-mvp-adversarial-review.md)
- **Architectural Decisions:** [`DECISIONS.md` §§8–12](../../DECISIONS.md)

> **Note on Phase Naming:** Earlier sections of [`DECISIONS.md`](../../DECISIONS.md) referred to the three internal layers of the initial build (`Domain`, `Db`, `Api`) as "Phase 1/2/3". At the product level, that initial MVP candidate was **Product Phase 1**. This document defines **Product Phase 2**, organized into three sequential tracks of concrete, commit-sized steps:
> - **Track A (Steps 1–6):** Frontend & UX Foundation (Servant `/static/*`, Pico CSS, Alpine.js micro-interactions, inline `/budget` editing) + MVP showstopper remediation (`v0.1.0` daily driver).
> - **Track B (Steps 7–12):** Security middleware, SQLite WAL concurrency, online backups, **CSV / CAMT.053 bank statement import**, and zero-warning `-Werror` CI.
> - **Track C (Steps 13–17):** Scheduled transactions & pure cash-flow projections (`v0.2.0` `/forecast`).

---

## Execution Rules for the Developer (Claude)

1. **One step (or tightly coupled pair) per PR/commit batch.** Keep diffs small and reviewable.
2. **Zero-build-step & strict JS boundary (`DECISIONS.md` §12):** No Node, npm, or bundlers. Static assets live in `static/` via Cabal `data-files`. Alpine.js is **strictly** for ephemeral local UI state (never persistent state, never `Float`/`Double` currency math — integer cents only even in JS previews!).
3. **Same-commit documentation rule (`CLAUDE.md`):** Update [`ARCHITECTURE.md`](../../ARCHITECTURE.md) in the **same commit** whenever a step adds/changes a route, static asset convention, database table, or domain rule.
4. **Total functions & strict warnings:** Maintain zero partial functions (`head`, `read`, `fromJust`, `error`) and keep `stack test` green at every commit.
5. **Handoff paper trail:** At the end of each Track (A, B, and C), write a concise handoff summary in `docs/handoffs/YYYY-MM-DD-phase-02-track-<x>.md` using [`docs/handoffs/TEMPLATE.md`](../handoffs/TEMPLATE.md).

---

## Track A — Frontend & UX Foundation + MVP Blocker Remediation

**Goal:** Establish the zero-build static asset pipeline (`Pico CSS` + `HTMX` + `Alpine.js`) at the very start so every subsequent fix and workflow (inline budget editing, dynamic N-way split editor, live reconciliation math, modals/shortcuts, transaction CRUD, month navigation) is built once on clean semantic HTML rather than rewritten twice.

### Step 1 — Servant Static-Asset Route (`/static/*`) & Vendored Frontend Libraries (`DECISIONS.md` §12, `H-5`)
- [ ] **Vendor assets in `static/`:** Add pinned, minified, zero-build files to `static/`:
  - `static/pico.min.css` (Pico CSS v2 semantic stylesheet — typography, tables, forms, `<dialog>`, responsive `.container`, automatic light/dark mode).
  - `static/htmx.min.js` (HTMX 2.0.3 — replaces the `unpkg.com` CDN `<script>` tag so Bucktracker works **100% offline**).
  - `static/alpine-csp.min.js` (or `static/alpine.min.js` — see `DECISIONS.md` §12 CSP note; prefer `@alpinejs/csp` + `static/app.js` registering `Alpine.data(...)` helpers so Step 7's `Content-Security-Policy` can keep strict `script-src 'self'` without `'unsafe-eval'`).
  - `static/app.js` — tiny, plain ES6 file holding integer-cent preview helpers (`parseEuroCents`, `formatEuroCents`) and Alpine component definitions (`splitEditor`, `reconcileCalc`, `inlineAssign`, global keyboard shortcuts).
- [ ] **Wire Cabal `data-files` & `AppEnv`:** Add `static/*.css` and `static/*.js` under `data-files:` in `package.yaml` (mirroring `migrations/*.sql`). Resolve `staticDir <- (</> "static") <$> Paths_bucktracker.getDataDir` on startup (`Main.hs` + `Api.Setup`) and store `appStaticDir :: FilePath` on `AppEnv` (`src/Api/Monad.hs`).
- [ ] **Mount `"static" :> Raw` in `src/Api.hs`:** Serve `appStaticDir` via `Servant.Server.StaticFiles.serveDirectoryWebApp` (built into `servant-server`, zero new dependencies). Ensure `<script defer src="/static/...">` ordering loads `app.js` / `alpine` cleanly alongside `htmx.min.js` (and re-initializes cleanly after HTMX fragment swaps).
- [ ] **Tests & Docs:** Verify `GET /static/pico.min.css`, `GET /static/htmx.min.js`, and `GET /static/app.js` return `200 OK` with expected `Content-Type` headers in `test/Api/`, and document `/static/*` in `ARCHITECTURE.md`.

### Step 2 — Semantic Pico CSS Layout, HTMX Fragment Fix & Progressive Form Fallbacks (`S-1`, `H-5`)
- [ ] **Adopt semantic Pico markup (`src/Api/Html.hs`):**
  - Update `page` to link `/static/pico.min.css`, `/static/htmx.min.js`, `/static/app.js`, and `/static/alpine-csp.min.js` (`defer_ ""`), replacing custom inline CSS boilerplate with minimal semantic overrides (e.g., `.error`, `.success`, right-aligned numeric columns).
  - Structure `body_` semantically as `<header class="container"><nav>...</nav></header><main class="container">...</main>` so Pico styles navigation, tables, forms, `<article>` cards, and `<dialog>` elements automatically in both light and dark mode without utility-class clutter.
  - Add reusable Lucid attribute helpers needed across Track A (`hxConfirm_`, `hxTrigger_`, `hxGet_`, `xData_`, `xShow_`, `xText_`, `xOn_`, etc.).
- [ ] **Fix HTMX full-page double-nesting bug (`S-1`):** Separate `GET` full-page handlers from `POST` fragment rendering in `src/Api/Transactions.hs` and `src/Api/Budget.hs` so HTMX swaps **only** `#transactions-content` / `#budget-content` (never nesting `<!DOCTYPE html>` or duplicate `<nav>` bars).
- [ ] **Add progressive enhancement on all forms:** Add `method_ "post"` and `action_ "<route>"` to every `<form>` across all pages, and inspect `Header "HX-Request" Text` so plain non-HTMX browser POSTs receive a full `page` wrapper while HTMX requests receive the bare `#...-content` fragment.
- [ ] **Tests:** Assert in all `Api.*Spec` modules that `POST` requests with `HX-Request: true` return fragments free of `<!DOCTYPE html>` and `<nav>`, while `GET` requests include Pico/HTMX/Alpine `/static/*` tags.

### Step 3 — Shared Overflow-Safe `Api.Money` Codec & Inline Cell Editing on `/budget` (`S-2`, `S-4` partial)
- [ ] **Extract `src/Api/Money.hs`:** Deduplicate the 3 copy-pasted `centsToEuroText` / `parseEuros` blocks in `Api.Accounts`, `Api.Transactions`, and `Api.Budget`:
  - `parseSignedEuros :: Text -> Maybe Cents` — supports optional leading `-` and both `.` and `,` decimal separators (`"-25.50"`, `"12,34"`), bounded to ±€100,000,000,000 (`abs whole <= 100_000_000_000`) so `whole * 100 + frac` can **never** overflow `Int64`.
  - `parseNonZeroSignedEuros :: Text -> Maybe Cents` — signed, rejects `0.00`.
  - `parsePositiveEuros :: Text -> Maybe Cents` — strictly `> zeroCents` (for transfers, or unsigned amounts).
  - Fix `centsToEuroText` using `Integer` `quotRem` so `cents minBound` formats cleanly without double-minus or sign errors.
- [ ] **Inline Cell Editing on `/budget` (`src/Api/Budget.hs`, `DECISIONS.md` §12):**
  - Replace the detached top-of-page assignment form as the primary workflow: render each active category row's **`Assigned`** cell as an inline click-to-edit control (`x-data="inlineAssign(...)"`).
  - Clicking the `Assigned` amount reveals an inline `<input>` pre-filled with the current euro amount (supporting negative assignments like `-50.00` to move rolled-over funds back to Ready to Assign!).
  - Pressing `Enter` or blurring after a change (`change`) submits `POST /budget/assign` via HTMX and swaps `#budget-content` (atomically updating `Ready to Assign`, the row's `Available`, and group subtotals); pressing `Escape` cancels and restores the original display value without a server round-trip. Keep a standard `<noscript>` / progressive `<form>` inside the cell so non-JS form submission still works.
- [ ] **Budget table clarity (`src/Api/Budget.hs`):**
  - Add the **`Carried In`** column (`Carried In | Assigned | Activity | Available`) so `Carried In + Assigned + Activity == Available` is visibly self-consistent on every row.
  - Group categories visually under their `CategoryGroup` headers, and hide archived categories whose `Carried In`, `Assigned`, `Activity`, and `Available` are all `0.00` (while keeping all categories in `rolloverMonths` so Invariant 1 always holds).
- [ ] **Tests:** `test/Api/MoneySpec.hs` (signed, comma decimal, zero rejection, `Int64` overflow rejection, `minBound` formatting) + `test/Api/BudgetSpec.hs` (positive & negative inline assignment updates, `Carried In` visibility).

### Step 4 — Alpine.js Micro-Interactions: Dynamic Splits, Live Reconciliation & Shortcuts (`DECISIONS.md` §12, `S-2`)
- [ ] **Dynamic N-way Split Editor + Live Unallocated Cents (`src/Api/Transactions.hs`, `static/app.js`):**
  - Replace the rigid 3-slot `NewSpendingForm` with repeated form fields (`lineCategoryId`, `lineAmount`) parsed via an explicit `FromForm` instance (`lookupAll`), unlocking arbitrary `1..N` `NonEmpty TransactionLine` splits end-to-end! Support category refunds/credits cleanly (either signed line amounts or an Expense / Refund mode toggle).
  - Add an Alpine `splitEditor` component that:
    1. Lets the user enter an optional receipt total and dynamically **"+ Add split line"** / **"Remove"** rows in the DOM without a server round-trip.
    2. Live-calculates `Receipt Total − Sum(Split Lines) = Unallocated Remaining` in **integer cents** in `/static/app.js` (highlighting in red/amber until `Remaining == 0.00`, while Haskell still derives `transactionAmount` strictly from the submitted lines per Invariant 3!).
- [ ] **Live Reconciliation Difference on `/accounts` (`src/Api/Accounts.hs`, `static/app.js`):**
  - Update `reconcileAccountHandler` to use `parseSignedEuros` (removing `min_ "0"`) so overdrawn checking or negative-balance liability accounts can be reconciled.
  - Pass each account's `clearedBalance` (in integer cents via `data-cleared-cents`) into an Alpine `reconcileCalc` wrapper on the reconcile `<dialog>` / inline drawer so as the user types their bank statement figure, the UI immediately displays `Cleared (€X) − Statement (€Y) = Difference (€Z)` in real time before they even click "Reconcile".
- [ ] **Lightweight `<dialog>` Modals/Drawers & Keyboard Shortcuts (`src/Api/Html.hs`, `src/Api/Transactions.hs`, `static/app.js`):**
  - Declutter `/transactions` by housing the Inflow / Expense / Transfer entry forms inside clean semantic HTML `<dialog>` modals or collapsible `<details>`/drawers controlled by Alpine, plus global keyboard shortcuts when not focused in an input (e.g., `n` opens New Expense `<dialog>`, `i` opens New Inflow, `t` opens Transfer, `Escape` closes any open `<dialog>` or inline edit).
- [ ] **Tests:** `Api.TransactionsSpec` testing 1-line, 2-line, and 5-line dynamic splits, category refunds, and negative inflows; `Api.AccountsSpec` testing negative statement reconciliation.

### Step 5 — Transaction Delete/Edit, Month Navigation & Register Completeness (`S-3`, `S-4`)
- [ ] **Transaction Delete & Edit (`src/Domain/Error.hs`, `src/Db/Transaction.hs`, `src/Api/Transactions.hs`):**
  - Add `CannotModifyReconciledTransaction` to `DomainError`.
  - Implement atomic `deleteTransaction`: block if `Reconciled`; if `TransferLeg`, delete **both** legs sharing `transfer_id` and the `transfers` row in one transaction; verify `ON DELETE CASCADE` removes `transaction_lines`.
  - Implement `updateTransaction` (date, payee, account, category/split lines, or transfer amount/accounts) upholding all on-budget, distinct-account, matching-budget-status, and non-reconciled invariants.
  - Expose Edit (`<dialog>` / inline row) and Delete (`hx-confirm`) controls on `/transactions`.
- [ ] **Month Navigation & Local Timezone (`src/Api/Budget.hs`, `src/Api/Transactions.hs`):**
  - Switch `utctDay <$> getCurrentTime` to local system date (`getZonedTime`), pre-fill `<input type="date">` with today's local date, and preserve user inputs on validation error.
  - Add `?month=YYYY-MM` (`QueryParam "month" Text`) + `← Prev | YYYY-MM | Next →` navigation on both `/budget` and `/transactions`, and show a `successBanner` with a link when a newly created transaction falls outside the currently viewed month.
- [ ] **Register Account Column & Per-Account Filter (`src/Api/Transactions.hs`, `src/Api/Accounts.hs`):**
  - Add the missing **`Account`** column to `transactionsTable`, support `?account=<id>` filtering on `/transactions`, and link account names on `/accounts` to `/transactions?account=<id>`.

### Step 6 — Two-Way Archiving, Server-Side Entity Guards & Track A Sign-Off (`H-1`, `H-2`, `L-1`, `L-2`)
- [ ] Add idempotent `archive*` (`WHERE id = ? AND archived_at IS NULL`), `unarchiveAccount`, `unarchiveCategoryGroup`, and `unarchiveCategory` in `Db.Account` / `Db.Category`, plus `hx-confirm` on every `Archive` button and `Unarchive` controls on `/accounts` and `/categories` (`DECISIONS.md` §11).
- [ ] Enforce server-side guards in `Db.*` (returning `DomainError`s): reject new transactions/assignments on archived accounts/categories, reject creating categories in archived groups, block archiving accounts/categories with non-zero balances (or active child categories), filter `Tracking` accounts out of the Spending form's account picker, hide `reconcileForm` on archived accounts, and show onboarding empty states when zero accounts/categories exist.
- [ ] Fix doc drift (`ARCHITECTURE.md`, `Api/Transactions.hs` header comment, `package.yaml` `github: "jus2tin/bucktracker"`, `CHANGELOG.md`).
- [ ] **Track A Exit Gate:** Write `docs/handoffs/YYYY-MM-DD-phase-02-track-a.md`. Bucktracker is now a complete, polished, offline-capable daily money tracker.

---

## Track B — Security, Concurrency, Backups, Bank Import & CI

**Goal:** Harden localhost security and SQLite concurrency, deliver automatic/manual backups, eliminate manual data-entry drudgery via **CSV / CAMT.053 bank statement import**, and lock everything behind `-Werror` CI.

### Step 7 — Localhost Security Middleware: CSRF, DNS Rebinding, Body Limits & Strict CSP (`H-4`, `H-5`)
- [ ] Create `src/Api/Middleware.hs` and wrap `Api.application`:
  1. **`Host` allowlist (DNS-rebinding defense):** Accept only `localhost`, `localhost:<port>`, `127.0.0.1`, or `127.0.0.1:<port>` (`403 Forbidden` otherwise).
  2. **Same-origin mutation check (CSRF defense):** On `POST`/`PUT`/`PATCH`/`DELETE`, require `Sec-Fetch-Site: same-origin` (or `Origin` matching `http://localhost:<port>` / `http://127.0.0.1:<port>`).
  3. **Request body size cap:** Enforce a reasonable body limit (e.g., 64 KB on standard form routes, 10 MB strictly on the Step 10 statement-import route; `413 Payload Too Large` otherwise).
  4. **Security headers:** `Content-Security-Policy` (`default-src 'self'; script-src 'self'` with `@alpinejs/csp`, `style-src 'self' 'unsafe-inline'; frame-ancestors 'none'`), `X-Frame-Options: DENY`, `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`.
- [ ] **Tests:** `test/Api/SecuritySpec.hs` covering forged `Host`, cross-origin `POST`, oversized payloads, and CSP headers.

### Step 8 — SQLite WAL Concurrency, Single-Checkout Snapshots & Batched Reads (`H-6`, `M-2`, `M-5`)
- [ ] Fix `src/Db/Pool.hs` & `app/Main.hs`: `PRAGMA busy_timeout = 5000` **first** in `openConfigured`, `PRAGMA journal_mode = WAL` + `synchronous = NORMAL` **once** in `createPool`, `bracketOnError` on connection/pool setup, and `bracket (createPool ...) closePool` in `Main.hs`.
- [ ] Add `withImmediateTransaction` (`BEGIN IMMEDIATE`) in `Db` for all multi-statement writes (`insertSpending`, `insertTransfer`, `updateTransaction`, `deleteTransaction`, `setTransactionCleared`, `applyMigration`), move `requireAccount` inside the write transaction (fixing TOCTOU), replace unexported `UnknownAccount` with `DomainError` (`AccountNotFound` / `CategoryNotFound`), export `CorruptRow`, and match `"categorized"` explicitly in `rowToTransaction`.
- [ ] Collapse multiple `withConn` calls per HTTP handler in `src/Api/*` into **one `withConn` per request** (inside a consistent read transaction for multi-table reads), and replace the N+1 `fetchLines` loop in `Db.Transaction` with a single batched `transaction_lines` query.

### Step 9 — Domain, Validation, Config & Schema Guardrails (`M-1`, `M-3`, `M-4`, `M-5`, `L-3`)
- [ ] Reject `amount <= zeroCents` in `mkTransferPair` / `insertTransfer`, bound `mkYearMonth` to `1900..9999`, bound `splitEvenly`, trim and cap names/payees (`<= 120` chars, no control chars) in `Domain.Validation`, and validate `BUCKTRACKER_PORT` (`1..65535`) + `nonempty` `BUCKTRACKER_DB_PATH` in `Config.hs`.
- [ ] Add `migrations/0002_import_index_and_constraints.sql` creating:
  - `CREATE UNIQUE INDEX idx_transactions_account_import_hash ON transactions (account_id, import_hash) WHERE import_hash IS NOT NULL;` (scoped per account so importing statements across multiple accounts never collides, while guaranteeing DB-level idempotency per account!).
  - Index on `assignments (year, month)`.

### Step 10 — Bank Statement Import: CSV & CAMT.053 with `ImportHash` Deduplication (`DECISIONS.md` §12)
- [ ] **Pure Import Engine (`src/Domain/Import.hs`, `Domain/Import/Csv.hs`, `Domain/Import/Camt053.hs`):**
  - Define `RawStatementRow` (`rsrDate :: Day`, `rsrAmount :: Cents`, `rsrPayee :: Text`, `rsrDescription :: Text`, `rsrBankRef :: Maybe Text`, `rsrImportHash :: ImportHash`).
  - **CAMT.053 parser (ISO 20022 XML):** Parse `<BkToCstmrStmt>` / `<Stmt>` / `<Ntry>` entries (booking/value date, EUR `<Amt>` signed via `<CdtDbtInd>` `CRDT`/`DBIT`, debtor/creditor `<RltdPties>` name, `<RmtInf>` remittance description, and `<AcctSvcrRef>` / `<EndToEndId>`), using a lightweight pure XML package from `lts-24.68` (e.g., `xml` or `xml-conduit`, no TemplateHaskell). Reject non-EUR statements with a clear `DomainError`.
  - **CSV parser:** Total parser supporting `,` and `;` delimiters, quoted fields, ISO (`YYYY-MM-DD`) and European (`DD-MM-YYYY` / `DD/MM/YYYY`) dates, and `.` / `,` decimal amounts (single signed column or separate Debit/Credit columns) via clean column-mapping presets.
  - **Collision-safe deterministic `ImportHash`:** Compute a canonical SHA-256 hex digest (e.g., via `crypton` / `cryptohash-sha256` in `lts-24.68`) over `(accountId, isoDate, centsValue, bankRefOrPayeeAndDesc, occurrenceIndexInFile)`. Including `occurrenceIndexInFile` (0th, 1st, 2nd identical tuple in that statement) ensures two real €2.50 coffees on the same day are **both** imported, while uploading the exact same statement file a second time skips 100% of rows!
- [ ] **Database Deduplication & Atomic Batch Commit (`src/Db/Import.hs` or `Db.Transaction`):**
  - `findExistingImportHashes :: Connection -> AccountId -> [ImportHash] -> IO (Set ImportHash)` to flag already-imported rows during preview.
  - `commitImportedTransactions` inside a single `BEGIN IMMEDIATE` transaction: inserts selected rows as `Cleared` (`Inflow`, `Categorized`, or `Transfer` via `insertTransfer` when matched to another account), skipping any row whose `(account_id, import_hash)` already exists, and upholding `isOnBudget` / `sameBudgetStatus` invariants.
- [ ] **Import Preview & Categorization UI (`src/Api/Import.hs`, mounted at `/import` + nav link):**
  - **Step 1 (Upload):** Select target `Account`, format (`CAMT.053 XML` or `CSV` preset), and upload statement file (via bounded `wai-extra` multipart parsing or `servant-multipart`, no TH).
  - **Step 2 (Interactive Preview & Categorize):** Render parsed rows in a Pico table showing new rows vs. *"Already imported — will skip"* badges:
    - On `Tracking` accounts, new rows default directly to `Inflow` adjustments (one click to import).
    - On `OnBudget` accounts, inflows default to `Ready to Assign` (or an optional category), while expenses require selecting a `Category` (or `Transfer` counterpart account) — preserving Invariant 5! Include an Alpine convenience helper so picking a category for `"Albert Heijn"` offers to auto-fill the same category on other `"Albert Heijn"` rows in the preview before submitting.
  - **Step 3 (Commit):** `POST /import/commit` persists all categorized rows atomically and redirects/renders a summary banner (`"Imported N transactions (M duplicates skipped)"`).
- [ ] **Tests:** `test/Domain/ImportSpec.hs` (CAMT.053 sample fixtures, CSV dialect fixtures, QuickCheck idempotency + same-day identical coffee preservation), `test/Db/ImportSpec.hs` (re-import deduplication, cross-account isolation), and `test/Api/ImportSpec.hs`.

### Step 11 — Harden & Wire Online Backups (`H-3`, `DECISIONS.md` §7)
- [ ] Refactor `src/Db/Backup.hs` to step in bounded chunks (`100` pages) with brief backoff on contention, reject `destPath == sourcePath`, create parent directories, and write to `<destPath>.tmp` + atomic `renameFile`.
- [ ] Take an automatic pre-migration backup (`<dbDir>/backups/pre-migration-<timestamp>.db`) when pending migrations exist on a non-empty DB, and add a `POST /backups` UI button saving timestamped snapshots into `<dbDir>/backups/`.

### Step 12 — Test Suite Cleanup, Zero-Warning Build & GitHub Actions CI (`M-6`, `L-4`, `L-5`)
- [ ] Clean up leaked pools and temp `.db`/`.db-wal`/`.db-shm` files in `test/Api/Setup.hs` (`around` + `bracket`), replace `BSL8.unpack` with UTF-8 `Text` helpers, verify non-mutation on rejected POSTs, and expand `Domain.Gen` edge cases.
- [ ] Prune unused dependencies in `package.yaml`, resolve `-Worphans` cleanly, verify `stack test --ghc-options=-Werror` passes with **0 warnings**, and add `.github/workflows/ci.yml` (Windows + Ubuntu).
- [ ] **Track B Exit Gate:** Write `docs/handoffs/YYYY-MM-DD-phase-02-track-b.md` and tag **`v0.1.0`**!

---

## Track C — Scheduled Transactions & Cash-Flow Projections (`v0.2.0`, `DECISIONS.md` §10)

**Goal:** Deliver recurring bills/income and future cash-flow/envelope simulation on `/forecast` while keeping `/budget` and `transactions` 100% strictly historical/present-tense.

### Architectural Rulings on `DECISIONS.md` §10's Open Questions

1. **Recurrence Rule Representation:** Closed, total sum type (`Once | Weekly | EveryNDays PositiveInt | EveryNMonths PositiveInt`, clamping anchor day-of-month via `fromGregorian` so Jan 31 → Feb 28/29 → Mar 31) rather than RFC 5545 `RRULE` strings.
2. **Lifecycle State:** `ScheduledItem` carries `siPaused :: Bool`, `siArchivedAt :: Maybe UTCTime`, optional `siEndDate :: Maybe Day`, and `siLastConfirmedDay :: Maybe Day` (preventing double-counting of occurrences already posted to the real ledger).
3. **Projection Horizon:** Default **6 months** on `/forecast`, with `?months=3|6|12` selector (capped at `24` months server-side).

### Step 13 — Pure `Domain.Schedule` & `Domain.Projection` Engine (`test/Domain/ProjectionSpec.hs`)
- [ ] Implement `src/Domain/Schedule.hs` (`ScheduledItem`, `ScheduledAction`, `RecurrenceRule`, smart constructors, total `occurrencesInRange`) and `src/Domain/Projection.hs` (pure simulation expanding active schedules into synthetic future events and folding `Domain.Budget.rolloverMonths` forward into `ProjectedWorld`, with projected account runway and category shortfall warnings).
- [ ] **QuickCheck properties (`test/Domain/ProjectionSpec.hs`):** Projected Invariant 1 holds at every simulated month; empty schedule list equals pure carry rollover; day-31 monthly clamping never drifts or crashes.

### Step 14 — Persistence Layer for Scheduled Items (`migrations/0003_scheduled_items.sql`, `src/Db/ScheduledItem.hs`)
- [ ] Create `scheduled_items` and `scheduled_item_lines` with strict `CHECK` constraints, plus CRUD, pause/archive, and atomic `confirmScheduledOccurrence` (inserting the real `Transaction` and advancing `last_confirmed_date` inside one `BEGIN IMMEDIATE` transaction).

### Step 15 — Scheduled Items Management UI & "Post to Ledger" Workflow (`src/Api/Schedules.hs`)
- [ ] Build `/schedules` (with Pico `<dialog>` forms + Alpine dynamic split support reused from Step 4!) for creating, pausing, archiving, and one-click **"Post to Ledger"** confirmation of due items.

### Step 16 — `/forecast` Cash-Flow & Envelope Projection Page (`src/Api/Forecast.hs`)
- [ ] Mount `/forecast` (`?months=3|6|12`) displaying account cash-flow runway & lowest-balance overdraft alerts, month-by-month projected category `Available` balances (highlighting upcoming negative shortfalls), and net-worth/savings trajectory — while verifying `/budget` remains strictly real cash only.

### Step 17 — `v0.2.0` Documentation Sync, Handoff & Architect Review #2
- [ ] Sync `ARCHITECTURE.md` and `CHANGELOG.md` (`0.2.0.0`), confirm `stack test --ghc-options=-Werror` is green, write `docs/handoffs/YYYY-MM-DD-phase-02-track-c.md`, and run Architect Milestone Review #2 for `v0.2.0` sign-off.
