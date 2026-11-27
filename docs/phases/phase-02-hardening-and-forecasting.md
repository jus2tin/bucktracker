# Phase 2 Plan — v0.1 Completion, Hardening & v0.2 Cash-Flow Forecasting

- **Date:** 2026-11-27
- **Author:** Gemini (Architect), for Justin (Product Owner) & Claude (Developer)
- **Prerequisite Review:** [`docs/reviews/2026-11-27-mvp-adversarial-review.md`](../reviews/2026-11-27-mvp-adversarial-review.md)

> **Note on Phase Naming:** Earlier sections of [`DECISIONS.md`](../../DECISIONS.md) referred to the three internal layers of the initial build (`Domain`, `Db`, `Api`) as "Phase 1/2/3". At the product level, that entire MVP candidate was **Product Phase 1**. This document defines **Product Phase 2**, organized into three sequential tracks of concrete, commit-sized steps:
> - **Track A (Steps 1–6):** Fix MVP showstoppers & complete `v0.1.0` daily-driver usability.
> - **Track B (Steps 7–11):** Security, SQLite concurrency, online backups & zero-warning CI.
> - **Track C (Steps 12–16):** Scheduled transactions & pure cash-flow projections (`v0.2.0` `/forecast`).

---

## Execution Rules for the Developer (Claude)

1. **One step (or tightly coupled pair) per PR/commit batch.** Keep diffs small and reviewable.
2. **Same-commit documentation rule (`CLAUDE.md`):** Update [`ARCHITECTURE.md`](../../ARCHITECTURE.md) in the **same commit** whenever a step adds/changes a route, database table, or domain rule.
3. **Total functions & strict warnings:** Maintain zero partial functions and ensure every step keeps `stack test` green.
4. **Handoff paper trail:** At the end of each Track (A, B, and C), write a concise handoff summary in `docs/handoffs/YYYY-MM-DD-phase-02-track-<x>.md` using [`docs/handoffs/TEMPLATE.md`](../handoffs/TEMPLATE.md).

---

## Track A — v0.1 Release Blockers (Make the MVP Usable Daily)

**Goal:** Eliminate all 4 showstoppers (`S-1`–`S-4`) and unfinished `v0.1` UX gaps (`H-1`, `H-2`, `L-1`, `L-2`) so the Product Owner can safely enter and manage real household finances.

### Step 1 — Fix HTMX Double-Page Nesting & Progressive Form Fallback (`S-1`, `H-5`)
- [ ] **Fix fragment rendering:** Separate full-page rendering (`GET /transactions`, `GET /budget`) from fragment rendering (`renderFragment` on `POST` actions) in `src/Api/Transactions.hs` and `src/Api/Budget.hs`, matching `Api.Accounts` and `Api.Categories` so HTMX swaps **only** `<div id="transactions-content">` / `<div id="budget-content">`.
- [ ] **Add progressive HTML form attributes:** Add `method_ "post"` and `action_ "<route>"` to all 9 `<form>` elements across `Api.Accounts`, `Api.Categories`, `Api.Transactions`, and `Api.Budget`.
- [ ] **Handle non-HTMX submissions cleanly:** Inspect the `HX-Request` request header (via Servant `Header "HX-Request" Text` or WAI): return the bare `#...-content` fragment when `HX-Request == Just "true"`, and wrap in `Api.Html.page` when submitted as a plain browser POST (e.g., if JS/HTMX is unavailable).
- [ ] **Tests:** Add assertions in `Api.AccountsSpec`, `Api.CategoriesSpec`, `Api.TransactionsSpec`, and `Api.BudgetSpec` verifying that `POST` requests with `HX-Request: true` **never** contain `<!DOCTYPE html>` or `<nav>`.

### Step 2 — Extract Shared, Overflow-Safe `Api.Money` Codec & Support Signed Workflows (`S-2`)
- [ ] **Deduplicate money parsing/formatting:** Create `src/Api/Money.hs` (or `Domain.Money`) and remove the 3 copy-pasted `centsToEuroText` / `parseEuros` / `centsFromParts` / `parseInt64` blocks from `Api.Accounts`, `Api.Transactions`, and `Api.Budget`.
- [ ] **Provide explicit parsers by domain intent:**
  - `parseSignedEuros :: Text -> Maybe Cents` — accepts optional leading `-` (and `,` or `.` decimal separator, e.g., `"-25.50"` or `"12,34"`). Use this for:
    - **Budget assignments (`/budget/assign`):** allows negative assignments to move rolled-over funds back to Ready to Assign (remove `min_ "0"` on `assignAmount`).
    - **Account reconciliation (`/accounts/:id/reconcile`):** allows reconciling overdrawn or liability accounts (remove `min_ "0"` on `statementBalance`).
    - **Inflows (`/transactions/inflow`, non-zero):** allows negative opening balances or balance adjustments while rejecting `0.00`.
    - **Categorized lines (`/transactions/spending`, non-zero):** either allow signed expense/refund amounts (e.g., positive expense vs. refund toggle/sign) or add a clear "Refund / credit" option so category returns credit the category directly rather than Ready to Assign.
  - `parsePositiveEuros :: Text -> Maybe Cents` — strictly `> zeroCents` (rejects `<= 0`). Use this for **transfers** (`/transactions/transfer`).
- [ ] **Overflow & `minBound` safety:** Bound parsed whole euros to a safe ceiling (e.g., `abs whole <= 100_000_000_000`, i.e., ±€100B, well below `Int64` overflow when multiplied by `100`) and fix `centsToEuroText` to use `Integer` (or `quotRem`) so `cents minBound` formats without double-minus or modulo sign bugs.
- [ ] **Tests:** Unit/property tests in `test/Api/MoneySpec.hs` covering negative values, `,` decimals, zero rejection, `Int64` overflow inputs, and `cents minBound` round-tripping. Update `ARCHITECTURE.md` ("Where do I change X?").

### Step 3 — Add Transaction Delete & Edit Capabilities (`S-3`)
- [ ] **Domain errors:** Add `CannotModifyReconciledTransaction` (and `TransactionNotFound TransactionId` if appropriate) to `src/Domain/Error.hs`.
- [ ] **Database layer (`src/Db/Transaction.hs`):**
  - Implement `deleteTransaction :: Connection -> TransactionId -> IO (Either DomainError ())`:
    - Reject deleting a `Reconciled` transaction (or require unreconciling explicitly; never silently alter reconciled bank history).
    - If the target row is a `TransferLeg` (`kind = 'transfer'`), atomically delete **both** legs sharing `transfer_id` and the parent `transfers` row (rejecting if either leg is `Reconciled`).
    - For `Categorized` transactions, `ON DELETE CASCADE` on `transaction_lines` cleans up split lines automatically (verify in tests!).
  - Implement `updateTransaction` (or edit routes for inflow/spending/transfer) upholding on-budget, distinct-account, matching-budget-status, and non-reconciled invariants.
- [ ] **UI & API (`src/Api/Transactions.hs`):** Add a `Delete` button (with `hx-confirm`) and an edit workflow per non-`Reconciled` row on `/transactions`.
- [ ] **Tests:** `Db.TransactionSpec` + `Api.TransactionsSpec` covering single-transaction deletion, atomic two-leg transfer deletion (verifying Invariant 1 & Invariant 2 still hold), cascade deletion of split lines, and rejection on `Reconciled` transactions.

### Step 4 — Month Navigation, Local Timezone & Register/Budget Table Completeness (`S-4`)
- [ ] **Local date & form ergonomics:** Replace `utctDay <$> getCurrentTime` with local system date (`localDay . zonedTimeToLocalTime <$> getZonedTime`) in `Api.Transactions` and `Api.Budget`; default `<input type="date">` fields to today's local date; preserve user-submitted form values when re-rendering after a validation error.
- [ ] **Month picker (`?month=YYYY-MM`):** Add an optional `QueryParam "month" Text` (`YYYY-MM`) + Previous / Current / Next month navigation controls to both `/budget` and `/transactions`. When a user adds a transaction dated outside the currently viewed month, display a `successBanner` with a clickable link to that transaction's month.
- [ ] **Transactions register columns (`Api.Transactions`):** Add the missing **`Account`** column to `transactionsTable` and an optional `?account=<id>` filter so users can inspect a single account's register (wiring `Db.Transaction.listTransactionsForAccount` or month+account filtering), plus clickable links from `/accounts` rows to `/transactions?account=<id>`.
- [ ] **Budget table clarity (`Api.Budget`):**
  - Add the **`Carried In`** column (`Carried In | Assigned | Activity | Available`) so every row's math (`Carried In + Assigned + Activity == Available`) is transparent on screen.
  - Group categories visually under their `CategoryGroup` headers.
  - Keep **all** categories in `rolloverMonths` (preserving Invariant 1), but hide archived categories from the rendered table when `cmCarriedIn == 0 && cmAssigned == 0 && cmActivity == 0 && available cm == 0` (still showing archived categories that hold a non-zero balance so money is never hidden!).

### Step 5 — Two-Way Archiving with Confirmation & Server-Side Entity Guards (`H-1`, `H-2`)
- [ ] **Unarchive + idempotent archive (`DECISIONS.md` §11):**
  - Update `archiveAccount`, `archiveCategoryGroup`, and `archiveCategory` to use `WHERE id = ? AND archived_at IS NULL` and return whether a row was updated.
  - Add `unarchiveAccount`, `unarchiveCategoryGroup`, and `unarchiveCategory` (`SET archived_at = NULL`) in `Db.Account` and `Db.Category`, plus `Unarchive` buttons on `/accounts` and `/categories`.
  - Add `hx-confirm` attributes (`hxConfirm_`) to every `Archive` button across `/accounts` and `/categories`.
- [ ] **Enforce archived & budget-type rules server-side (`Domain.Error` + `Db.*` + `Api.*`):**
  - Reject creating categories inside an archived `CategoryGroup`, posting new transactions to archived accounts/categories, and assigning funds to archived categories (via `DomainError` variants enforced in `Db.*`, not just HTML dropdown filtering).
  - Exclude `Tracking` accounts from `newSpendingForm`'s account `<select>` (`filter (\a -> not (isArchived a) && isOnBudget a)`).
  - Hide `reconcileForm` on archived accounts (`Api.Accounts`).
  - Block (or warn with `DomainError`) archiving an on-budget account with `accountBalance /= 0` or a category with `available /= 0` in the current month, and block archiving a `CategoryGroup` while it still has active child categories (or cascade-archive child categories with zero available balance).
  - Render helpful empty-state onboarding prompts on `/budget` and `/transactions` when no active accounts or categories exist yet (disabling submit buttons instead of showing empty `<select>` boxes).

### Step 6 — Fix Documentation Drift & Prepare `v0.1.0` Milestone Gate (`L-1`, `L-2`)
- [ ] Fix `ARCHITECTURE.md` inaccuracies (`insertSpending` description, `renderFragment` description, and the `Api.Money` reference), remove the stale comment in `src/Api/Transactions.hs:14-16`, fix `github: "jus2tin/bucktracker"` in `package.yaml`, and write the `0.1.0.0` section in `CHANGELOG.md`.
- [ ] **Track A Exit Gate:** Write `docs/handoffs/YYYY-MM-DD-phase-02-track-a.md`. At this point, `v0.1.0` is functionally complete and truthful to every promise in `DECISIONS.md` §§1–5 & §11.

---

## Track B — Security, SQLite Concurrency & Operational Hardening

**Goal:** Resolve the deferred architectural & security backlog (`DECISIONS.md` §§6–8) so Bucktracker is safe against browser-based localhost attacks, resilient under concurrent HTMX load, backed up automatically, and guarded by `-Werror` CI.

### Step 7 — Vendored HTMX, Security Headers & CSRF / DNS-Rebinding Middleware (`H-4`, `H-5`)
- [ ] **Vendor HTMX locally:** Add `static/htmx-2.0.3.min.js` to Cabal `data-files` in `package.yaml`, serve `/static/htmx.min.js` from `Api`, and update `Api.Html.page` to `<script src="/static/htmx.min.js">`. Bucktracker now runs **100% offline** with zero third-party requests.
- [ ] **Add `src/Api/Middleware.hs`:** Wrap `Api.application` with WAI middleware that:
  1. **Blocks DNS rebinding:** Rejects requests whose `Host` header is not `localhost`, `localhost:<port>`, `127.0.0.1`, or `127.0.0.1:<port>` (`403 Forbidden`).
  2. **Blocks CSRF:** On unsafe methods (`POST`, `PUT`, `PATCH`, `DELETE`), requires `Sec-Fetch-Site: same-origin` (or `Origin` matching `http://localhost:<port>` / `http://127.0.0.1:<port>`), rejecting cross-site submissions with `403 Forbidden`.
  3. **Bounds request bodies:** Rejects request bodies larger than 64 KB (`413 Payload Too Large`).
  4. **Sets security headers:** `Content-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; frame-ancestors 'none'`, `X-Frame-Options: DENY`, `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`.
- [ ] **Tests:** `test/Api/SecuritySpec.hs` testing forged `Host`, cross-site `Origin` / `Sec-Fetch-Site: cross-site`, oversized POST bodies, security headers, and `/static/htmx.min.js` delivery.

### Step 8 — SQLite WAL Concurrency, Single-Checkout Snapshots & Batched Reads (`H-6`, `M-2`, `M-5`)
- [ ] **Pool & PRAGMA lifecycle (`src/Db/Pool.hs`, `app/Main.hs`):**
  - In `openConfigured`, wrap `open` with `bracketOnError`, run `PRAGMA busy_timeout = 5000` **first**, then `PRAGMA foreign_keys = ON` and `PRAGMA synchronous = NORMAL`.
  - Run `PRAGMA journal_mode = WAL` **once** in `createPool` (not on every pooled connection), clean up `pool` via `onException` if `runMigrations` fails, and wrap `Main.main` in `bracket (createPool ...) closePool`.
- [ ] **Immediate write transactions & typed lookup errors (`src/Db/Transaction.hs`):**
  - Implement `withImmediateTransaction` (`BEGIN IMMEDIATE` / `COMMIT` / `ROLLBACK` under `mask`) and use it for all multi-statement writes (`insertSpending`, `insertTransfer`, `setTransactionCleared`, `deleteTransaction`, `applyMigration`), eliminating deferred write-upgrade `SQLITE_BUSY` failures and moving `requireAccount` *inside* the transaction (fixing TOCTOU).
  - Replace unexported `UnknownAccount` with `DomainError` (`AccountNotFound AccountId` / `CategoryNotFound CategoryId`); export `CorruptRow`; replace the wildcard `_` in `rowToTransaction` with explicit `"categorized"` matching.
- [ ] **Single-checkout handlers & N+1 elimination (`src/Api/*`, `src/Db/Transaction.hs`):**
  - Refactor each handler in `Api.Accounts`, `Api.Categories`, `Api.Transactions`, and `Api.Budget` to borrow **one** `Connection` per HTTP request (`withConn $ \conn -> ...`), wrapping multi-table reads in a consistent `DEFERRED` read snapshot.
  - Replace per-row `fetchLines` in `listTransactionsForAccount`, `listTransactionsInMonth`, and `listAllTransactions` with a single batched query loading `transaction_lines` (grouped in Haskell via `Data.Map.Strict`), reducing 2,000+ queries per `/budget` load to **2 queries**.

### Step 9 — Domain, Validation, Config & Schema Guardrails (`M-1`, `M-3`, `M-4`, `M-5`, `L-3`)
- [ ] Reject `amount <= zeroCents` in `mkTransferPair` and `insertTransfer` (`TransferAmountMustBePositive`), bound `mkYearMonth` to `1900 <= y && y <= 9999` (`InvalidYear Int`), and bound `splitEvenly` / `scaleCents`.
- [ ] Update `Domain.Validation.nonEmptyName` to return the **trimmed** name (`Text.strip`), enforce a max length (e.g., 120 characters, `NameTooLong`), reject control characters, and apply length validation to transaction `payee` as well.
- [ ] Validate `BUCKTRACKER_PORT` (`1..65535`) and `nonempty` `BUCKTRACKER_DB_PATH` in `src/Config.hs`.
- [ ] Add `migrations/0002_constraints_and_indexes.sql` adding a partial unique index on `transactions (import_hash) WHERE import_hash IS NOT NULL` and any non-invasive indexes (`assignments (year, month)`). Document why `0001_initial.sql`'s `PRAGMA foreign_keys = ON` is historic and keep `0001_initial.sql` immutable (since it is already applied in existing DBs).

### Step 10 — Harden & Wire Online Backups (`H-3`, `DECISIONS.md` §7)
- [ ] **Harden `src/Db/Backup.hs`:**
  - Step in chunks of e.g. `100` pages (`Raw.backupStep backup 100`), sleeping briefly (`threadDelay 25000`) if contended rather than holding one monolithic `-1` lock.
  - Canonicalize paths and reject `destPath == sourcePath`; create parent directories; write to `<destPath>.tmp` and atomically `renameFile` on `BackupDone` (removing `.tmp` on exception).
- [ ] **Wire into runtime:**
  - Automatically take a pre-migration backup (`backups/pre-migration-<timestamp>.db`) in `createPool` whenever pending migrations exist on a non-empty database file.
  - Add a `POST /backups` UI trigger (e.g., in navigation/settings or `/accounts`) that writes a timestamped snapshot into `<dbDir>/backups/bucktracker-<UTC-timestamp>.db` (never accepting user-supplied file paths over HTTP) and displays a `successBanner`.

### Step 11 — Test Suite Cleanup, Zero-Warning Build & GitHub Actions CI (`M-6`, `L-4`, `L-5`)
- [ ] Fix `test/Api/Setup.hs` (`around` + `bracket` closing the pool and deleting `.db`/`.db-wal`/`.db-shm` files after each test), clean up temp files in `MigrationsSpec` and `PoolSpec`, extract a shared UTF-8 `Api.TestHelpers` module (replacing `BSL8.unpack`), verify DB state on rejected POSTs, and expand `Domain.Gen` (days 29–31, Feb 29, Dec→Jan boundaries, `Tracking -> Tracking` transfers, distinct `TransferId`s).
- [ ] Remove unused dependencies in `package.yaml` (`aeson`, `transformers`, `uuid`, `warp` from `library`; scope `text`/`time` per component) and resolve `-Worphans` warnings cleanly (either via `{-# OPTIONS_GHC -Wno-orphans #-}` on `Db.Field` + dedicated row types in `Db.*`, or documented module pragma) so `stack build --test --ghc-options=-Werror` compiles with **zero warnings**.
- [ ] Add `.github/workflows/ci.yml` running `stack test --ghc-options=-Werror` on push and pull_request (Windows + Ubuntu matrix, caching `~/.stack` / `.stack-work`).
- [ ] **Track B Exit Gate:** Write `docs/handoffs/YYYY-MM-DD-phase-02-track-b.md` and tag **`v0.1.0`**!

---

## Track C — Scheduled Transactions & Cash-Flow Projections (`v0.2.0`, `DECISIONS.md` §10)

**Goal:** Deliver the Product Owner's core v0.2 capability — recurring bills, income, and future cash-flow/envelope projections on `/forecast` — while keeping the real ledger (`transactions`, `assignments`, `/budget`) 100% strictly historical/present-tense.

### Architectural Rulings on `DECISIONS.md` §10's Open Questions

To unblock implementation cleanly, the Architect proposes the following concrete rulings (subject to Product Owner override):

1. **Recurrence Rule Representation:** Use a closed, total Haskell sum type rather than RFC 5545 `RRULE` strings:
   ```haskell
   data RecurrenceFrequency
     = Once                           -- single future scheduled event on anchor date
     | Weekly                         -- every 7 days from anchor date
     | EveryNMonths PositiveInt       -- e.g., 1 = monthly, 3 = quarterly, 12 = yearly (clamping anchor day-of-month via fromGregorian, so anchor Jan 31 -> Feb 28/29 -> Mar 31)
   ```
   *Why:* Covers >98% of personal bills/paychecks (weekly, biweekly via `EveryNDays 14` if desired, monthly, quarterly, annual, one-off future tax bill), requires zero string parser complexity, makes illegal schedules unrepresentable, and is trivial to test with QuickCheck.
2. **Lifecycle State:** `ScheduledItem` carries both `siPaused :: Bool` (temporarily skip in projections without losing the schedule) and `siArchivedAt :: Maybe UTCTime` (soft delete, consistent with `Account` and `Category`), plus optional `siEndDate :: Maybe Day` and `siLastConfirmedDay :: Maybe Day` (so already-entered occurrences in the current month are not double-counted in projections!).
3. **Default Projection Horizon:** Default to **6 months** ahead on `/forecast`, with a simple selector for `3`, `6`, or `12` months (hard-capped at `24` months server-side to bound computation).

### Step 12 — Pure `Domain.Schedule` & `Domain.Projection` Engine (`test/Domain/ProjectionSpec.hs`)
- [ ] Create `src/Domain/Schedule.hs` defining `ScheduledItemId`, `ScheduledItem`, `ScheduledAction` (`ScheduledSpending (NonEmpty TransactionLine) | ScheduledInflow Cents | ScheduledTransfer AccountId Cents`), `RecurrenceRule`, smart constructors (enforcing positive transfer amounts, distinct accounts, non-empty payee), and total `occurrencesInRange :: ScheduledItem -> Day -> Day -> [Day]` (skipping dates `<= siLastConfirmedDay`, paused/archived items, and dates past `siEndDate`).
- [ ] Create `src/Domain/Projection.hs` (strictly pure: no `IO`, no `Db`):
  - Expand active `[ScheduledItem]` from `(today + 1 day)` (or unconfirmed occurrences from `startOfCurrentMonth`) through the end of `targetMonth` into synthetic `Transaction` values (validating on-budget rules).
  - Reuse `Domain.Budget.rolloverMonths` (and optionally carry forward recurring monthly budget template assignments or zero future assignments — document clearly!) to produce `ProjectedWorld`:
    - Month-by-month `MonthlyBudget`s (`[MonthlyBudget]`).
    - Projected end-of-month (and daily minimum / runway) balances per `Account`.
    - Category shortfall alerts (any category whose projected `available < zeroCents`).
- [ ] **QuickCheck properties (`test/Domain/ProjectionSpec.hs`):**
  1. **Projected Invariant 1:** At every projected month in `ProjectedWorld`, projected `onBudgetBalanceTotal == sum(projected category available) + projected Ready to Assign`!
  2. **Identity law:** Projecting with `[]` (no scheduled items) equals folding `rolloverMonths` with zero future activity.
  3. **Clamping totality:** Anchor day `31` in `EveryNMonths 1` produces valid dates in February (leap and non-leap) and 30-day months without drifting permanently to the 28th.

### Step 13 — Persistence Layer for Scheduled Items (`migrations/0003_scheduled_items.sql`, `src/Db/ScheduledItem.hs`)
- [ ] Add `migrations/0003_scheduled_items.sql` creating `scheduled_items` and `scheduled_item_lines` (for split recurring bills, mirroring `transactions` + `transaction_lines`) with strict `CHECK` constraints matching `ScheduledAction` and `RecurrenceRule`.
- [ ] Implement `src/Db/ScheduledItem.hs` (`insertScheduledItem`, `listScheduledItems`, `setScheduledItemPaused`, `archiveScheduledItem`, `unarchiveScheduledItem`, and atomic `confirmScheduledOccurrence` which inserts the real `Transaction` via `Db.Transaction` and updates `last_confirmed_date` inside one `BEGIN IMMEDIATE` transaction!).
- [ ] **Tests:** `test/Db/ScheduledItemSpec.hs` testing round-trip CRUD, on-budget/transfer validation, batched line loading, and atomic confirmation into the real ledger.

### Step 14 — Scheduled Items UI & "Confirm into Ledger" Action (`src/Api/Schedules.hs`)
- [ ] Build routes and HTMX UI at `/schedules` (or integrated cleanly alongside `/forecast` + nav link in `Api.Html`) to:
  - Create scheduled inflows, expenses (including splits), and transfers.
  - Pause/resume, archive/unarchive, or delete scheduled items (with `hx-confirm`).
  - Show **"Due / Upcoming"** items (`nextDueDay <= today`) with a one-click **"Post to Ledger"** button calling `confirmScheduledOccurrence` — turning a scheduled template into a real historical `Transaction` only upon explicit user action.
- [ ] **Tests:** `test/Api/SchedulesSpec.hs`.

### Step 15 — `/forecast` Cash-Flow & Envelope Projection Page (`src/Api/Forecast.hs`)
- [ ] Mount `ForecastApi` at `/forecast` (keeping `/budget` completely untouched and strictly real-money-only, per `DECISIONS.md` §10) with `?months=3|6|12` selector:
  - **Cash-Flow Runway & Lowest Balance Summary:** Projected balance per on-budget and tracking account at each month-end, highlighting the lowest projected daily balance (overdraft warning if `< €0.00`).
  - **Projected Category Balances Table:** Month-by-month projected `Available` per category, visually highlighting projected shortfalls (`< €0.00`) so the user sees upcoming underfunded bills months ahead.
  - **Savings / Net-Worth Trajectory:** Projected total on-budget cash + tracking balances over the selected horizon.
- [ ] **Tests:** `test/Api/ForecastSpec.hs` verifying that creating a scheduled bill changes `/forecast` while leaving `/budget` and `/accounts` completely unchanged until confirmed.

### Step 16 — `v0.2.0` Documentation Sync, Handoff & Architect Review #2
- [ ] Verify `ARCHITECTURE.md` and `CHANGELOG.md` (`0.2.0.0`) are fully up to date and `stack test --ghc-options=-Werror` passes cleanly.
- [ ] Write `docs/handoffs/YYYY-MM-DD-phase-02-track-c.md` and request Architect Milestone Review #2 for `v0.2.0` release sign-off.
