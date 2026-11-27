# Adversarial Architectural Review — Phase 1 (v0.1 MVP Candidate)

- **Date:** 2026-11-27
- **Reviewer:** Gemini (Architect)
- **Audited Commit:** `e393568` (`origin/main`, PR #7 — *"Split transactions; log archiving as a one-way trip"*)
- **Scope:** Full source, schema, configuration, test suite, and documentation audit following Developer report that the v0.1 MVP is ready.

---

## 1. Architect's Executive Verdict: **NO-GO for v0.1 Sign-Off (Conditional on Track A Remediation)**

The Developer delivered impressive velocity since the 2026-11-26 pre-MVP review:
- Bound Warp strictly to loopback `127.0.0.1` (`app/Main.hs`).
- Closed the `Tracking`-account spending loophole in both `Db.Transaction.insertSpending` and `Domain.Budget.categoryActivity`.
- Fixed Windows locale-dependent SQL decoding in `Db.Migrations.applyMigration` (`ByteString` + `decodeUtf8'`).
- Sealed `Account`, `CategoryGroup`, and `Category` constructors, implemented `clearedBalance` and multi-month `rolloverMonths` with QuickCheck coverage across consecutive months, translated the codebase to English, authored `ARCHITECTURE.md` and `README.md`, and built out `/categories`, `/transactions` (including 3-way splits and clear toggles), `/budget`, and `/accounts` (running balances + reconciliation).

**However, the MVP is not yet ready for real personal-finance use.** Auditing the newly added Phase 3 handlers and end-to-end workflows uncovered **four showstopper defects (S-1 through S-4)** — including live HTMX full-page DOM duplication on `/budget` and `/transactions`, unsigned-only euro parsing that traps rolled-over envelope funds and blocks negative reconciliation, zero ability to delete or edit a mistaken transaction, and a register locked to the current UTC month with no `Account` column — alongside **unfinished v0.1 items** explicitly flagged in `DECISIONS.md` §§6–11.

### Severity Overview

| Category | Count | Summary |
|---|---:|---|
| **Showstopper (Blocks v0.1 Use)** | 4 | HTMX full-page nesting bug on `/budget` & `/transactions`; unsigned `parseEuros` trapping budget money + `Int64` overflow; no transaction delete/edit; locked UTC month + missing `Account` & `Carried In` columns |
| **High (Incomplete v0.1 / Security / Concurrency)** | 6 | One-way unconfirmed archiving (`DECISIONS.md` §11); server-side archived-entity & dropdown bypasses; unwired `Db.Backup` dead code + locking/atomicity flaws; full-ledger CSRF & DNS rebinding; unpinned CDN HTMX without SRI/CSP/offline fallback; pool thrashing + torn reads + N+1 query explosion + WAL `SQLITE_BUSY` |
| **Medium (Hardening & Correctness)** | 6 | Transfer `amount <= 0` & `minBound` negation; unbounded `YearMonth` breaking text date queries; unstripped/unbounded names & request bodies; TOCTOU + unexported `UnknownAccount`; unvalidated `Config` & missing `closePool` shutdown; missing CI + `-Werror` blockers |
| **Low (Docs Drift & Test Blind Spots)** | 5 | `ARCHITECTURE.md` & header comment drift; empty `CHANGELOG.md` & wrong `package.yaml` GitHub slug; missing SQL `CHECK` constraints; `Api.*Spec` blind to full-page swaps & UTF-8; `Api.Setup` temp file/pool leaks |

---

## 2. Showstopper Findings (Must Fix Before Real Data Entry)

### S-1. Live HTMX Full-Document Nesting Bug on `/transactions` and `/budget`

- **Locations:** `src/Api/Transactions.hs:113-114, 202-209`, `src/Api/Budget.hs:74-75, 98-110`
- **Mechanics:**
  In `Api.Accounts` (`src/Api/Accounts.hs:70, 129-133`) and `Api.Categories` (`src/Api/Categories.hs:66, 106-110`), the `GET` handler wraps content in `Api.Html.page`, while `renderFragment` (called by every `POST` handler) returns **only** the `<div id="...-content">` fragment.
  In **`Api.Transactions`** and **`Api.Budget`**, `renderFragment` itself wraps the response in `page`:
  ```haskell
  -- src/Api/Transactions.hs:209
  pure (page "Transactions" (transactionsContent err accounts categories transactions))

  -- src/Api/Budget.hs:110
  pure (page "Budget" (budgetContent err groups categories (mbCategoryMonths currentBudget) (mbReadyToAssign currentBudget)))
  ```
  Meanwhile, every form and button on both pages targets `#transactions-content` or `#budget-content` with `hx-swap="outerHTML"` (and no `hx-select`).
- **Impact:** Every single form submission or "Clear" click on `/transactions` and every "Assign" click on `/budget` swaps an entire HTML document — including a duplicate `<nav>Budget · Accounts · Categories · Transactions</nav>`, `<style>`, and `<script src="https://unpkg.com/htmx.org@2.0.3">` — **inside** the existing `<body>`. Each click stacks another navigation bar down the page and re-executes the HTMX script tag.
- **Why tests missed it:** `Api.TransactionsSpec` and `Api.BudgetSpec` only check `bodyContains "<substring>"`, which passes whether the response is a fragment or a full HTML document. This also directly contradicts `ARCHITECTURE.md:84-95`.

### S-2. Unsigned-Only `parseEuros` Breaks Core Envelope Budgeting, Reconciliation & Refunds — Plus Silent `Int64` Overflow

- **Locations:** `src/Api/Accounts.hs:196-230`, `src/Api/Transactions.hs:324-385`, `src/Api/Budget.hs:186-228`
- **Mechanics:** The 35-line `parseEuros` / `centsToEuroText` block is copy-pasted identically across three API modules. `parseInt64` delegates to `Data.Text.Read.decimal`, which **only accepts unsigned digits (`0–9`)**, paired with `min="0"` on every HTML `<input type="number">`.
- **Four broken financial workflows:**
  1. **Rolled-over money is permanently trapped in categories (`Api.Budget`):** In zero-based envelope budgeting, moving €200 out of an envelope that carried in €500 from last month requires setting this month's `cmAssigned` to **`-€200.00`** (`available = €500 - €200 = €300`, returning `+€200.00` to Ready to Assign). `Domain.Budget` and `Domain.Gen` support negative `Assignment`s, but `Api.Budget` rejects negative inputs — once money rolls over into a new month, a user can **never** unassign it back to Ready to Assign.
  2. **Overdrawn or liability accounts cannot be reconciled (`Api.Accounts`):** If a checking account is overdrawn (`-€25.50`) or a `Tracking` account tracks a loan/mortgage (`-€150,000.00`), `reconcileAccountHandler` rejects `-25.50` with `"Invalid statement balance."` — making reconciliation impossible whenever `clearedBalance < 0`.
  3. **Categorized refunds/returns cannot be entered (`Api.Transactions`):** `parseRequiredLine` (`src/Api/Transactions.hs:352`) unconditionally negates unsigned `amt` (`negateCents amt`). A €40 clothing return cannot be credited back to `Clothing` (`+€40.00`); entering it as `Inflow` routes it to Ready to Assign instead of offsetting category spending.
  4. **Negative opening balances are impossible (`Api.Transactions`):** `DECISIONS.md` §3 models opening balances as `Inflow` transactions, which cannot be negative because `inflowAmount` rejects `-`.
- **Arithmetic & formatting defects in the same duplicated helpers:**
  - **Silent `Int64` overflow in `centsFromParts`:** `whole <- parseInt64 wholePart` accepts `100000000000000000` (`10^17`, valid `Int64`), after which `whole * 100 + frac` overflows `Int64` to `-8446744073709551616`. On the spending form, `negateCents` flips that overflowed negative back to **positive**, silently crediting quadrillions of euros from an expense input.
  - **Zero-amount ledger noise:** `parseEuros "0"` and `"0.00"` succeed everywhere, permitting €0.00 inflows, €0.00 spending lines, and €0.00 transfers.
  - **`centsToEuroText (cents minBound)` corruption:** `abs (minBound :: Int64)` evaluates to `minBound` (still negative), causing `div`/`mod` 100 to produce `"--92233720368547759.92"`.
  - **Locale friction:** Only `"."` is accepted as decimal separator; European users typing `"12,34"` get `"Invalid amount."`.

### S-3. Missing Essential CRUD: Transactions Cannot Be Deleted or Edited

- **Locations:** `src/Db/Transaction.hs:1-11`, `src/Api/Transactions.hs:63-69`
- **Problem:** Neither `Db.Transaction` nor `Api.Transactions` provides any way to **delete** or **edit** a transaction.
- **Impact:** A single typo (`1200.00` instead of `12.00`, wrong date, wrong category, accidental double-click) permanently corrupts the user's ledger unless they manually run raw SQL against `bucktracker.db`. Ironically, `Api.Accounts:120` instructs users on reconciliation mismatch to *"check for a missing, **duplicate**, or uncleared transaction"*, while offering no mechanism to remove a duplicate or fix an amount.
- **Architectural constraint for remediation:** Deleting or editing a transaction must respect two invariants:
  1. Deleting either leg of a `TransferLeg` must atomically delete **both** legs sharing `transfer_id` and the parent `transfers` row inside one `BEGIN IMMEDIATE` transaction (preserving Invariant 2).
  2. `Reconciled` transactions should be protected from casual deletion/amount mutation (requiring explicit confirmation or blocking with a `DomainError`) so historical bank reconciliations cannot silently drift.

### S-4. No Month Navigation, UTC Midnight Drift & Missing Columns on `/transactions` and `/budget`

- **Locations:** `src/Api/Transactions.hs:204-206, 239, 248, 269, 273-286`, `src/Api/Budget.hs:100, 112-113, 161-173`
- **Problems:**
  1. **Hardcoded current month with no month selector:** Both `/transactions` and `/budget` are locked to the current calendar month.
     - **Disappearing-transaction trap:** If on December 1st a user logs a November 30th receipt, `POST /transactions/spending` succeeds silently (`200 OK`, no confirmation banner), **and the new transaction never appears in the table** — prompting repeated duplicate submissions, with no way to navigate back to November.
     - **Cross-page balance discrepancy:** Entering a future-dated transaction immediately changes `/accounts` (`listAllTransactions`), while `/budget` (`currentMonthBudget`) only displays the current month with no way to inspect the future month.
  2. **UTC clock instead of local timezone:** Both `Api.Transactions:205` and `Api.Budget:113` compute the current month via `utctDay <$> getCurrentTime` (UTC) instead of the machine's local timezone (`getZonedTime`). Near month boundaries, non-UTC users see the wrong budget month.
  3. **Blank date inputs & wiped form state on error:** None of the three `<input type="date">` fields default to today's date, and any validation error re-renders blank forms, discarding everything the user typed.
  4. **Missing `Account` column on `/transactions` (`src/Api/Transactions.hs:275`):** `transactionsTable` merges transactions from *all* accounts into one chronological list (`Date | Payee | Category | Amount | Status | [Clear]`) without showing which account each transaction belongs to! Transfers appear as two ambiguous rows, and `Db.Transaction.listTransactionsForAccount` has no UI route.
  5. **Missing `Carried In` column & ungrouped rows on `/budget` (`src/Api/Budget.hs:163`):** `budgetTable` shows `Assigned | Activity | Available` without `cmCarriedIn`. Whenever prior-month funds roll over (`Carried In = 50.00, Assigned = 0.00, Activity = 0.00, Available = 50.00`), the visible row math doesn't add up. Categories are also rendered as a flat table rather than grouped under their `CategoryGroup`s.

---

## 3. High-Severity Findings: Unfinished Plans, Boundary Bypasses & Architecture Debt

### H-1. Unfinished v0.1 Blocker: Archiving Remains an Unconfirmed One-Way Door (`DECISIONS.md` §11)

- **Locations:** `DECISIONS.md:448-468`, `src/Db/Account.hs:53-56`, `src/Db/Category.hs:52-55, 79-82`, `src/Api/Accounts.hs:168-177`, `src/Api/Categories.hs:137-146, 175-184`
- **Problem:** `DECISIONS.md` §11 explicitly flagged *before calling v0.1 done* that archiving an account, category, or category group has neither an `hx-confirm` confirmation prompt nor an `unarchive` function/UI control anywhere in `Db.*` or `Api.*`. Both remain unimplemented. Additionally, `archive*` functions overwrite `archived_at` on repeated calls (`WHERE id = ?` without `AND archived_at IS NULL`) and silently succeed on non-existent IDs.

### H-2. Server-Side Archived-Entity Bypasses & UI Picker Traps

- **Locations:** `src/Api/Categories.hs:85-88`, `src/Api/Transactions.hs:124-128, 144-154, 171-175, 247`, `src/Api/Accounts.hs:164, 182`, `src/Api/Budget.hs:84-89, 106, 164`
- **Problems:**
  - **UI-only archive filtering:** Although `<select>` menus hide archived items, **none** of the `POST` handlers or `Db.*` repository functions reject archived entities:
    - `createCategoryHandler` allows creating new active categories inside an **archived** `CategoryGroup` (`any ((== gid) . cgId) groups` ignores `isArchivedGroup`).
    - `createInflowHandler`, `createSpendingHandler`, and `createTransferHandler` allow posting new transactions to **archived** accounts and **archived** categories.
    - `assignHandler` allows assigning funds to **archived** categories.
  - **`Tracking` accounts shown in the Spending form (`src/Api/Transactions.hs:247`):** `newSpendingForm` populates `spendingAccountId` with `activeAccounts accounts` — which includes `Tracking` accounts! If a user's first account is a `Tracking` account, the spending form defaults to an account guaranteed to fail with `"Categorized transactions are not allowed on tracking accounts."`
  - **Archived display leaks:** `Api.Accounts:164` still renders `reconcileForm` on archived accounts; `Api.Budget:164` renders archived categories forever in the budget table even when all four balances (`Carried In`, `Assigned`, `Activity`, `Available`) are `0.00`; archiving a `CategoryGroup` leaves its child categories active; and archiving an account or category with a non-zero balance gives no warning or guard (`DECISIONS.md` §8 H-5a).
  - **Cold-start UX:** On an empty database, `/` redirects to `/budget` where `<select>` pickers are empty while submit buttons remain active, yielding `"Unknown category."` instead of guiding the user to create accounts and categories first.

### H-3. `Db.Backup` Is Dead Code & Retains Locking / Non-Atomic Overwrite Bugs (`DECISIONS.md` §7 & §8 H-6)

- **Locations:** `src/Db/Backup.hs:1-32`
- **Problem:** Despite `DECISIONS.md` §7 selecting SQLite's online backup API *"from within the app itself"* as the project's backup strategy, `Db.Backup.backupTo` has **zero callers** in `app/` or `src/Api/` (neither automatic pre-migration backup nor user-triggered backup exists). Furthermore, `backupTo` still calls `Raw.backupStep backup (-1)` (holding a lock across the entire copy with no `SQLITE_BUSY`/`SQLITE_LOCKED` backoff), writes directly to `destPath` instead of a temp file + atomic rename, does not create parent directories, and does not guard against `destPath == sourcePath`.

### H-4. Full-Ledger CSRF & DNS Rebinding Exposure (`DECISIONS.md` §8 H-1, Escalated)

- **Locations:** `src/Api.hs:40`, all `POST` routes in `src/Api/*`
- **Problem:** When `H-1` was deferred in `DECISIONS.md` §8, only `/accounts` existed. Now **every financial mutation** (`POST /transactions/inflow`, `/transactions/spending`, `/transactions/transfer`, `/transactions/:id/clear`, `/budget/assign`, `/accounts/:id/reconcile`, `/accounts/:id/archive`, `/categories*`) accepts `application/x-www-form-urlencoded` requests without CSRF tokens, `Origin`/`Sec-Fetch-Site` checks, or `Host` header validation. Any malicious webpage opened in the user's browser can silently forge transactions, scramble budget assignments, or archive entities on `127.0.0.1:8080`, and DNS rebinding can read all financial pages cross-origin.

### H-5. External CDN Script Without SRI/CSP & Broken Non-JS Form Fallbacks (`DECISIONS.md` §8 H-2 & M-7)

- **Locations:** `src/Api/Html.hs:27`, all 9 `form_` declarations across `src/Api/Accounts.hs`, `Categories.hs`, `Transactions.hs`, `Budget.hs`
- **Problems:**
  1. `https://unpkg.com/htmx.org@2.0.3` is loaded with no Subresource Integrity (`integrity`), no `Content-Security-Policy`, no `X-Frame-Options: DENY` (clickjacking risk on archive/clear buttons), and no `X-Content-Type-Options: nosniff`.
  2. Every page load phones home to `unpkg.com`, and **the entire UI breaks when offline** — an unacceptable limitation for a local-first personal finance app when `htmx.min.js` (~16 KB gzipped) can be served locally via Cabal `data-files` just like `migrations/*.sql`.
  3. None of the 9 `<form>` elements specify `method_ "post"` or `action_ "..."`. Whenever HTMX fails to load (offline, CDN outage, script blocker), clicking submit triggers a browser `GET` request that appends sensitive financial fields (`?inflowPayee=...&inflowAmount=...`) into the URL and silently drops the write.

### H-6. Pool Thrashing, Torn Reads, N+1 Query Explosion & SQLite WAL `SQLITE_BUSY` (`DECISIONS.md` §8 H-3 & M-4, Escalated)

- **Locations:** `src/Api/Budget.hs:99-105`, `src/Api/Transactions.hs:144-159, 206-208`, `src/Api/Accounts.hs:68-69, 131-132`, `src/Db/Transaction.hs:92-125, 293-300`, `src/Db/Pool.hs:44-50`
- **Problems:**
  1. **Multi-checkout torn reads:** `Api.Budget.renderFragment` executes **5 separate `withConn` calls** per render (`7` pool checkouts for a single `POST /budget/assign`!). Because each call borrows an independent connection with no shared read transaction, concurrent activity across tabs can produce a torn snapshot where `onBudgetBalanceTotal /= categoryBalances + Ready to Assign` on screen.
  2. **Unbounded N+1 query amplification:** Both `Api.Accounts` and `Api.Budget` now invoke `Db.listAllTransactions` on **every page load and every HTMX button click**. `listAllTransactions` executes 1 `SELECT` on `transactions` plus **N separate `fetchLines` `SELECT`s** (one per categorized transaction across the user's entire history). With 2,000 expenses, clicking "Assign" on `/budget` fires **>2,000 SQLite queries**!
  3. **SQLite WAL lock-upgrade & PRAGMA ordering bugs (`H-3`):** `Db.Pool.openConfigured` still executes `PRAGMA journal_mode = WAL` on every new pooled connection *before* `PRAGMA busy_timeout = 5000`, and `Db.Transaction` uses `sqlite-simple`'s deferred `withTransaction` (`BEGIN DEFERRED`), which fails immediately with `SQLITE_BUSY` on concurrent read-to-write upgrades without honoring `busy_timeout`. `migrations/0001_initial.sql:13` also retains the no-op `PRAGMA foreign_keys = ON` inside a transaction.

---

## 4. Medium-Severity Findings

1. **M-1 — Transfer sign/zero & `Int64` boundary gaps (`src/Domain/Transaction.hs:109`, `src/Db/Transaction.hs:198`, `src/Domain/Types.hs:74-93`):** `mkTransferPair` and `insertTransfer` still accept `amount <= zeroCents` (reversing transfer direction or inserting zero-amount legs); `negateCents`/`scaleCents` are unchecked at `Int64` boundaries; `splitEvenly` has unbounded `O(n)` allocation on `n`.
2. **M-2 — TOCTOU & unexported exceptions in `Db.Transaction` (`src/Db/Transaction.hs:62, 166, 201-213`):** Both `insertSpending` (newly added) and `insertTransfer` call `requireAccount` *outside* the write transaction, and `UnknownAccount` / `CorruptRow` remain unexported `Exception` types that escape to Warp as unhandled HTTP 500s rather than typed `DomainError`s. `rowToTransaction` (`line 101`) also still uses a wildcard `_` instead of matching `"categorized"` explicitly.
3. **M-3 — Unbounded `YearMonth` years break SQLite text date comparisons (`src/Domain/Types.hs:104-108`, `src/Db/Transaction.hs:280`):** `mkYearMonth` accepts negative or 5+ digit years, which violate ISO-8601 lexicographical ordering in `WHERE date >= ? AND date < ?`.
4. **M-4 — Unstripped/unbounded text inputs & missing body limits (`src/Domain/Validation.hs:16-19`, `src/Api/*`):** `nonEmptyName` validates `Text.strip name` but stores unstripped whitespace (`"  Cash  "`), imposes no max length on account/category/payee names, and Warp has no request body size limit.
5. **M-5 — Config validation & resource cleanup gaps (`src/Config.hs:30-31`, `app/Main.hs:19-30`, `src/Db/Pool.hs:38-50`):** `BUCKTRACKER_PORT` lacks `1..65535` validation; `BUCKTRACKER_DB_PATH` accepts `""`; `Main.hs` never calls `closePool` via `bracket` on shutdown; `createPool` and `openConfigured` leak resources if migrations or PRAGMAs throw.
6. **M-6 — Deferred CI pipeline & `-Werror` blockers (`package.yaml`, `src/Db/*`, `DECISIONS.md` §§6–7):** CI was deferred *"until after the MVP"*. Enabling `-Werror` today will immediately fail compilation due to:
   - Unused `library` dependencies in `package.yaml`: `aeson`, `transformers`, `uuid`, and `warp` (note: `bytestring` *is* now used by `Db.Migrations` as of `1c2565f`, and `containers` by `Db.Migrations`), plus unused `text` and `time` inherited by `bucktracker-exe`.
   - Unsuppressed `-Worphans` warnings across `Db.Field`, `Db.Account`, `Db.Category`, `Db.Transaction`, and `Db.Assignment`.

---

## 5. Low-Severity Findings, Documentation Drift & Test Blind Spots

1. **L-1 — Documentation drift violating `CLAUDE.md`'s Documentation Standard:**
   - `ARCHITECTURE.md:76-83` inaccurately describes `Db.insertSpending`'s execution order, and `ARCHITECTURE.md:84-95` claims `Api.Transactions.renderFragment` returns only `#transactions-content` (masking **S-1**).
   - `ARCHITECTURE.md:286` cites `DECISIONS.md §8` as explaining why `centsToEuroText`/`parseEuros` are duplicated per module, but `DECISIONS.md §8` contains no mention of either function.
   - `src/Api/Transactions.hs:14-16` still states *"there's no multi-month rollover orchestrator either (see DECISIONS.md §8, H-5)"*, which became obsolete in commit `ab42b95`.
2. **L-2 — Release metadata & repo URL mismatch:** `CHANGELOG.md` is still an empty template (`## 0.1.0.0 - YYYY-MM-DD`), and `package.yaml:3` / `bucktracker.cabal:12-28` point to `github.com/justintermaat/bucktracker` instead of the actual remote `github.com/jus2tin/bucktracker`.
3. **L-3 — Database defense-in-depth `CHECK` constraints (`migrations/0001_initial.sql`):** Still missing DB-level checks for `account_id <> counterpart_account_id`, `amount <> 0` on transfers, `UNIQUE (transfer_id, account_id)`, `length(trim(name)) > 0`, `year BETWEEN 1900 AND 9999` on `assignments`, and a partial unique index on `import_hash`.
4. **L-4 — API test suite blind spots (`test/Api/*Spec.hs`):**
   - None of the 4 `Api.*Spec` files assert that HTMX mutation endpoints return partial fragments rather than full `<!DOCTYPE html>` documents (**S-1**).
   - Validation-failure tests (`"without adding a row"`) still do not re-query `GET` to confirm zero rows were persisted, do not check HTTP `303` status on `GET /`, and still decode bodies with Latin-1 `BSL8.unpack` (while `CategoriesSpec` mixes `BSL8.unpack` and `TLE.decodeUtf8` in the same file!).
5. **L-5 — Windows handle & temp-file leaks in tests (`test/Api/Setup.hs`, `test/Db/MigrationsSpec.hs`, `test/Db/PoolSpec.hs`):** `Api.Setup.withTestApp` now runs ~28 times per `stack test` invocation, leaking 28 pools (up to 224 SQLite connection slots) and leaving ~84 `.db`/`.db-wal`/`.db-shm` files in `%TEMP%` on every test run; `MigrationsSpec.tempMigrationFile` also leaves temp `.sql` files behind.

---

## 6. Architect Sign-Off Criteria

Before tagging **`v0.1.0`** and starting **`v0.2.0` (Forecasting)**, the Developer must complete **Track A (Steps 1–6)** — and ideally **Track B (Steps 7–11)** — in [`docs/phases/phase-02-hardening-and-forecasting.md`](../phases/phase-02-hardening-and-forecasting.md).
