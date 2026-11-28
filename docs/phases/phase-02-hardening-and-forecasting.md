# Phase 2 Plan — Frontend & UX Foundation, Hardening, Bank Import & Forecasting

- **Date:** 2026-11-27
- **Author:** Gemini (Architect), for Justin (Product Owner) & Claude (Developer)
- **Prerequisite Review:** [`docs/reviews/2026-11-27-mvp-adversarial-review.md`](../reviews/2026-11-27-mvp-adversarial-review.md)
- **Architectural Decisions:** [`DECISIONS.md` §§8–13](../../DECISIONS.md)

> **Note on Phase Naming:** Earlier sections of [`DECISIONS.md`](../../DECISIONS.md) referred to the three internal layers of the initial build (`Domain`, `Db`, `Api`) as "Phase 1/2/3". At the product level, that initial MVP candidate was **Product Phase 1**. This document defines **Product Phase 2+**, organized into sequential tracks of concrete, commit-sized steps:
> - **Track A (Steps 1–6 — ✅ Complete):** Frontend & UX Foundation (Servant `/static/*`, Pico CSS, Alpine.js micro-interactions, inline `/budget` editing) + MVP showstopper remediation + post-Track-A `AUDIT-01..08` hardening (`c599309`, `9ae5492`).
> - **Track B (Steps 7–9, 11–12):** Security middleware, SQLite WAL concurrency, online backups, and zero-warning `-Werror` CI — **`v0.1.0` sign-off gate** (turnkey spec: [`track-b-spec.md`](track-b-spec.md)).
> - **Track C (Step 10):** ABN AMRO `CAMT.053` / `.TAB` bank statement import (turnkey spec: [`track-c-abn-amro-import-spec.md`](track-c-abn-amro-import-spec.md)).
> - **Track D (Steps 13–17 + R-1..R-4):** Zero-JS Net-Worth & Monthly Spending Reports (`/reports`, spec: [`track-d-reporting-spec.md`](track-d-reporting-spec.md)) + Scheduled Cash-Flow Projections (`/forecast`).
> - **Track E (Planned — Post-Tracks B–D):** Recurring Obligations & Fixed Bills (`/recurring`, charter: [`track-e-recurring-spec.md`](track-e-recurring-spec.md)).

> **Amendment (2026-11-27, Product Owner decision, following Developer feedback on this plan):** The original Track B bundled three differently-sized efforts into one review/merge unit — security & CSRF middleware, SQLite concurrency fixes, and a full CAMT.053/CSV bank-import feature (XML parsing, deterministic dedup hashing, a whole import preview UI). The PO agreed these shouldn't land together and split bank import into its own **Track C**, renumbering the former Track C (Scheduled Transactions & Forecasting) to **Track D**. Step numbers themselves are unchanged — Step 10 is still "Step 10", just filed under the new Track C heading instead of Track B. The PO also confirmed explicitly: **`v0.1.0` is tagged at the end of the (now security/concurrency/CI-only) Track B, not at Track A alone** — even though Track A's own exit gate already produces a fully usable daily driver, hardening is treated as part of the release gate, not an optional follow-up. Track C (bank import) does not block the `v0.1.0` tag and may land before or after it.

---

## Execution Rules for the Developer (Claude)

1. **One step (or tightly coupled pair) per PR/commit batch.** Keep diffs small and reviewable.
2. **Code-Only File-Ownership Firewall (`CLAUDE.md` / `GEMINI.md`):** Touch **only** `src/**`, `app/**`, `migrations/*.sql`, `test/**/*.hs`, `static/**`, `package.yaml`, and `stack.yaml`. Do **not** edit Markdown docs (`ARCHITECTURE.md`, `DECISIONS.md`, `CHANGELOG.md`, `docs/**`) — Carbon updates all documentation and handoffs after your commits.
3. **Zero-build-step & strict JS boundary (`DECISIONS.md` §12):** No Node, npm, or bundlers. Static assets live in `static/` via Cabal `data-files`. Alpine.js is **strictly** for ephemeral local UI state (never persistent state, never dynamic string interpolation in `x-*` attributes, never `Float`/`Double` currency math — integer cents only even in JS previews!).
4. **Total functions & single-pass test runs:** Maintain zero partial functions (`head`, `read`, `fromJust`, `error`) and verify each step with a single `stack test --fast --test-arguments="--format=progress"`.

---

## Track A — Frontend & UX Foundation + MVP Blocker Remediation

**Goal:** Establish the zero-build static asset pipeline (`Pico CSS` + `HTMX` + `Alpine.js`) at the very start so every subsequent fix and workflow (inline budget editing, dynamic N-way split editor, live reconciliation math, modals/shortcuts, transaction CRUD, month navigation) is built once on clean semantic HTML rather than rewritten twice.

### Step 1 — Servant Static-Asset Route (`/static/*`) & Vendored Frontend Libraries (`DECISIONS.md` §12, `H-5`) ✅ Done
- [x] **Vendor assets in `static/`:** Add pinned, minified, zero-build files to `static/`:
  - `static/pico.min.css` (Pico CSS **v2.1.1** semantic stylesheet — typography, tables, forms, `<dialog>`, responsive `.container`, automatic light/dark mode).
  - `static/htmx.min.js` (HTMX **2.0.3** — replaces the `unpkg.com` CDN `<script>` tag so Bucktracker works **100% offline**).
  - `static/alpine-csp.min.js` (Alpine.js **`@alpinejs/csp` 3.17.5** — the CSP-safe build per `DECISIONS.md` §12).
  - `static/app.js` — present but deliberately a placeholder for now; the integer-cent preview helpers and Alpine component definitions land in Steps 3–4.
- [x] **Wire Cabal `data-files` & `AppEnv`:** `static/*.css`/`static/*.js` added to `data-files:` in `package.yaml`; `appStaticDir :: FilePath` added to `AppEnv` (`src/Api/Monad.hs`), resolved via `Paths_bucktracker.getDataDir` in both `app/Main.hs` and `test/Api/Setup.hs`.
- [x] **Mount `"static" :> Raw` in `src/Api.hs`:** Served via `serveDirectoryWebApp`. (The `<script defer src="/static/...">` tags themselves are **not** added yet — pages still load HTMX from the CDN; wiring `Api.Html.page` to the new assets is Step 2's job, see `ARCHITECTURE.md` "Static assets".)
- [x] **Tests & Docs:** `test/Api/StaticSpec.hs` (new) verifies `GET /static/pico.min.css`, `/static/htmx.min.js`, `/static/alpine-csp.min.js`, and `/static/app.js` return `200` with the right content-type family, and that an unknown asset 404s. `ARCHITECTURE.md` documents `/static/*` (new "Static assets" section + a "Where do I change X?" row).

### Step 2 — Semantic Pico CSS Layout, HTMX Fragment Fix & Progressive Form Fallbacks (`S-1`, `H-5`) ✅ Done
- [x] **Adopt semantic Pico markup (`src/Api/Html.hs`):**
  - `page` now links `/static/pico.min.css`, `/static/htmx.min.js`, `/static/alpine-csp.min.js`, and `/static/app.js` (all `defer_ ""`), replacing the old inline CSS boilerplate with minimal overrides (`.error`, `.success`, `.amount` for right-aligned numeric columns).
  - `body_` is now `<header class="container"><nav>...</nav></header><main class="container">...</main>`.
  - Added `hxGet_`, `hxConfirm_`, `hxTrigger_`, `xData_`, `xShow_`, `xText_`, `xOn_` (unused for now — land with Steps 3-4/6).
- [x] **Fixed the HTMX full-page double-nesting bug (`S-1`):** `Api.Transactions`/`Api.Budget` no longer wrap every response in `page` unconditionally. A single new `Api.Html.pageOrFragment` (named to avoid colliding with `Servant.respond`) decides fragment vs. full page from the `HX-Request` header, and every one of the four pages' mutating handlers goes through it now (not just the two that had the bug).
- [x] **Progressive enhancement on all forms:** every `<form>` across all four pages now has `method_ "post"`/`action_ "<route>"` alongside its `hx-*` attributes; every previously-bare `hx-post` button (archive, clear) is now wrapped in its own single-button `<form>` too, so it still does something when HTMX hasn't loaded. Every mutating route gained `Header "HX-Request" Text` as its first handler argument.
- [x] **Tests:** `Api.Setup.postHtmlFormHx` (new) sends `HX-Request: true`; each `Api.*Spec` now asserts a plain POST gets a full page (`<!doctype html>`/`<nav>`) while an HTMX POST gets a bare fragment, and that `GET` responses link the `/static/*` assets. 109 examples, 0 failures.

### Step 3 — Shared Overflow-Safe `Api.Money` Codec & Inline Cell Editing on `/budget` (`S-2`, `S-4` partial) ✅ Done
- [x] **Extracted `src/Api/Money.hs`:** `parseSignedEuros` (optional leading `-`, `.`/`,` decimal, bounded to ±€100,000,000,000 so `whole * 100 + frac` can't overflow `Int64`), `parseNonZeroSignedEuros`, `parsePositiveEuros` (strictly `> zeroCents`), and `centsToEuroText` (via `Integer`, so `cents minBound` formats cleanly). `Api.Transactions` (inflow/transfer/split amounts) and `Api.Budget` (assigned amount) now use it; `Api.Accounts`'s reconcile field deliberately stays on its own local non-negative-including-zero parser until Step 4 (see `ARCHITECTURE.md`'s "Where do I change X?").
- [x] **Inline Cell Editing on `/budget`:** the detached top-of-page form is gone; each row's **Assigned** cell is a click-to-edit control backed by an Alpine `inlineAssign` component (`static/app.js`, registered via `Alpine.data` — the CSP build needs the component script loaded *before* Alpine's own script tag, and every `x-on` handler to call `()` explicitly rather than a bare reference; both were real bugs caught live in a browser, not just in `stack test`). Enter or a real `change` submits via HTMX; Escape restores the display value with no server round-trip. Supports negative amounts (`-50.00`) to move rolled-over funds back to Ready to Assign — verified live end-to-end (typed `-15.00`, watched Ready to Assign and Available update correctly). Without JS it's still a plain `<form>`; Enter-to-submit works via implicit form submission.
- [x] **Budget table clarity:** added the **Carried In** column; categories are now grouped under their `CategoryGroup` as a heading row instead of a repeated flat column; an archived category whose Carried In/Assigned/Activity/Available are all `0.00` is hidden (still included in `rolloverMonths` so Invariant 1 holds over the full ledger regardless of what's on screen).
- [x] **Tests:** `test/Api/MoneySpec.hs` (21 cases: signed, comma decimal, zero rejection, `Int64` overflow/bound rejection, `minBound` formatting, a round-trip property) + new `Api.BudgetSpec` cases (negative assignment, Carried In column, hide/show archived zero-vs-nonzero balance). 134 examples, 0 failures.

### Step 4 — Alpine.js Micro-Interactions: Dynamic Splits, Live Reconciliation & Shortcuts (`DECISIONS.md` §12, `S-2`) ✅ Done
- [x] **Dynamic N-way Split Editor + Live Unallocated Cents (`src/Api/Transactions.hs`, `static/app.js`):**
  - `NewSpendingForm` dropped `deriving (FromForm)` for a hand-written instance: `lineCategoryId`/`lineAmount` repeat once per line and are collected via `Web.FormUrlEncoded.lookupAll`, zipped back into pairs by position (`parseSplitLines`), so `1..N` lines reach `Db.insertSpending`'s existing `NonEmpty TransactionLine` with no artificial cap. Refunds/credits use signed line amounts (`Api.Money.parseNonZeroSignedEuros`), not a mode toggle — the existing `negateCents` convention turns a typed negative into a stored credit for free.
  - Added the Alpine `splitEditor` component: "+ Add split line"/"Remove" clone/remove a plain `.split-line` DOM node (deliberately not `x-for`/`<template>`, to avoid depending on more elaborate templating support from the CSP build); live-calculates `Receipt Total − Sum(Split Lines) = Unallocated Remaining` in integer cents, with a ✓ once it's exactly zero. (Scope note: the preview is plain text, not red/amber-highlighted as the plan originally sketched — color-coding would need a conditional `x-bind:class`, and simple correctness took priority given the CSP build's already-demonstrated quirks.)
  - `NewInflowForm`'s amount is signed too now (`parseNonZeroSignedEuros`) — closes S-2.4 (an opening-balance correction can be negative); a transfer's amount stays strictly positive.
- [x] **Live Reconciliation Difference on `/accounts` (`src/Api/Accounts.hs`, `static/app.js`):**
  - `reconcileAccountHandler` now uses `parseSignedEuros` (was a local non-negative-only parser) — an overdrawn checking or negative-balance liability account can reconcile.
  - Added the Alpine `reconcileCalc` component: reads the account's `clearedBalance` off a `data-cleared-cents` attribute the server renders, and shows `Cleared (€X) − Statement (€Y) = Difference (€Z)` live as the user types, before clicking "Reconcile".
- [x] **Lightweight `<details>` Drawers & Keyboard Shortcuts (`src/Api/Transactions.hs`, `static/app.js`):** the Inflow/Expense/Transfer forms are each wrapped in a plain `<details>`/`<summary>` (the plan's own simpler alternative to a `<dialog>` modal — no JS needed for open/close, no focus-trap to get wrong). A document-level `keydown` listener (plain JS, not an Alpine component) opens the matching drawer on `n`/`i`/`t` and focuses its first field, ignoring the key while focus is already in a form field or a modifier is held; `Escape` closes whichever drawer is open, from anywhere on the page.
- [x] **Tests:** `Api.TransactionsSpec` — 2-line and 5-line dynamic splits, a negative-line-amount refund, a rejected zero-amount line, a negative and a rejected zero-amount inflow. `Api.AccountsSpec` — negative (overdrawn) statement reconciliation. 140 examples, 0 failures.
- **Also fixed along the way:** `/static/*` was served with `serveDirectoryWebApp`'s default one-year `Cache-Control: max-age` — fine for content-hashed CDN assets, wrong for unhashed files that change on every step. A stale cached `app.js` surviving a rebuild is exactly what live-browser verification caught here; switched to `serveDirectoryWith` with `ssMaxAge = NoMaxAge` (`src/Api.hs`, see `ARCHITECTURE.md` "Static assets"). Also: `inlineAssign`'s `submitEdit` now guards against a double POST (Enter can trigger both its own handler and a subsequent `change` event); the client-side `parseEuroCents` preview now rejects a partially-numeric string (`"12abc"`) instead of silently accepting `Number.parseInt`'s partial parse.

### Step 5 — Transaction Delete/Edit, Month Navigation & Register Completeness (`S-3`, `S-4`) ✅ Done
- [x] **Transaction Delete & Edit (`src/Domain/Error.hs`, `src/Db/Transaction.hs`, `src/Api/Transactions.hs`):**
  - Added `CannotModifyReconciledTransaction` to `DomainError`.
  - `deleteTransaction` and the new `updateInflow`/`updateSpending`/`updateTransfer` all go through a shared `withReplaceable`: block if `Reconciled`, otherwise delete the old row(s) (both legs + the shared `transfers` row, for a transfer) and — for an edit — insert the new ones, in one SQL transaction. An edit is delete-then-reinsert through the same raw row-insert helpers (`insertInflow`/`insertSpendingRows`/`insertTransferRows`) a fresh create uses, each `update*` repeating its matching `insert*`'s own validation first (on-budget-only, distinct accounts, matching budget status) — never a bespoke `UPDATE` re-deriving those invariants separately. `ON DELETE CASCADE` on `transaction_lines` relies on the same `PRAGMA foreign_keys = ON` every connection already sets (`Db.Pool`), not new wiring.
  - Exposed an "Edit" `<details>` drawer per row (pre-filled, reusing the create-form renderers and the Step 4 split editor) and a "Delete" button with `hx-confirm`; both hidden once a transaction is `Reconciled`.
  - **Tests:** `test/Db/TransactionSpec.hs` (delete of a plain transaction and of both transfer legs, blocked-on-Reconciled for both delete and each `update*`, each `update*`'s own validation re-checked); `test/Api/TransactionsSpec.hs` (delete/edit through the HTTP layer for all three kinds).
- [x] **Month Navigation & Local Timezone (`src/Api/Monad.hs`, `src/Api/Budget.hs`, `src/Api/Transactions.hs`):**
  - `Api.Monad.localToday` (via `getZonedTime`, not `getCurrentTime`/`utctDay`) is the one shared local-date source; both pages' date inputs now pre-fill with it.
  - `Api.Monad.resolveViewedMonth` + `Domain.Types.yearMonthToText`/`parseYearMonth` (the canonical `"YYYY-MM"` text form) are shared by both pages' `?month=YYYY-MM` + `<- Prev | YYYY-MM | Next ->` navigation (a plain `<ul>`, not a `<nav>` — see ARCHITECTURE.md). Budget's inline-assign form carries the viewed month in a hidden `assignMonth` field so assigning while browsing a past/future month assigns into *that* month.
  - **Scope note — two sub-items not done:** "preserve user inputs on validation error" and "a `successBanner` when a created transaction falls outside the viewed month" were both dropped to keep this already-large step shippable; see ARCHITECTURE.md "Month navigation, local dates, and the account filter" for the related, intentional simplification that every mutating action on `/transactions` re-renders the *default* view (today's month, no filter) rather than threading the viewed month/filter through all six of that page's forms. None of this is a correctness issue — a failed form always still shows the error message, just with its own fields reset — but it's real, deferred UX polish, not an oversight.
  - **Tests:** `test/Domain/TypesSpec.hs` (`yearMonthToText`/`parseYearMonth` round-trip property + unit cases); `test/Api/BudgetSpec.hs` and `test/Api/TransactionsSpec.hs` (month nav links, viewing/rolling into a month, falling back on a missing/invalid `?month=`).
- [x] **Register Account Column & Per-Account Filter (`src/Api/Transactions.hs`, `src/Api/Accounts.hs`):**
  - Added the missing **Account** column to `transactionsTable`; `?account=<id>` filters the register (riding along on the Prev/Next links so it survives month navigation) with an `accountFilterBanner` ("Showing: X [show all accounts]"); account names on `/accounts` now link to `/transactions?account=<id>`.
  - **Tests:** `test/Api/TransactionsSpec.hs` (filtering, the Account column, the Accounts-page link).

### Step 6 — Two-Way Archiving, Server-Side Entity Guards & Track A Sign-Off (`H-1`, `H-2`, `L-1`, `L-2`) ✅ Done
- [x] Added idempotent `archive*` (`WHERE id = ? AND archived_at IS NULL`), `unarchiveAccount`, `unarchiveCategoryGroup`, and `unarchiveCategory` in `Db.Account` / `Db.Category`, plus `hx-confirm` on every `Archive` button and `Unarchive` controls on `/accounts` and `/categories` (`DECISIONS.md` §11, commit `c599309`).
- [x] Enforced server-side guards: rejected new transactions/assignments on archived accounts/categories (and cross-archive reassignment on edits via `movesOntoArchived*`), rejected creating categories in archived groups (`ArchivedCategoryGroup`), blocked archiving accounts with non-zero balance or unreconciled rows and categories with non-zero balance in any month `>= today` (`AUDIT-04`), filtered `Tracking` accounts out of the Spending form's account picker, hid `reconcileForm` on archived accounts, and added first-run onboarding banners.
- [x] Resolved all post-Track-A audit tickets (`AUDIT-01`..`AUDIT-08`, commit `9ae5492`; 222 passing tests) and synced `ARCHITECTURE.md`, `DECISIONS.md`, `package.yaml` (`github: "jus2tin/bucktracker"`), and `CHANGELOG.md`.
- [x] **Track A Exit Gate:** Recorded in [`docs/handoffs/2026-11-27-phase-02-track-a.md`](../handoffs/2026-11-27-phase-02-track-a.md). Bucktracker is now a complete, polished, offline-capable daily money tracker.

---

## Track B — Security, Concurrency, Backups & CI

**Goal:** Harden localhost security and SQLite concurrency, deliver automatic/manual backups, and lock everything behind `-Werror` CI. **This track's exit gate is the `v0.1.0` release tag** (see the 2026-11-27 amendment above) — Track C (bank import, below) is split out and does not block it.

### Step 7 — Localhost Security Middleware: CSRF, DNS Rebinding, Body Limits & Strict CSP (`H-4`, `H-5`)
- [ ] Create `src/Api/Middleware.hs` and wrap `Api.application`:
  1. **`Host` allowlist (DNS-rebinding defense):** Accept only `localhost`, `localhost:<port>`, `127.0.0.1`, or `127.0.0.1:<port>` (`403 Forbidden` otherwise).
  2. **Same-origin mutation check (CSRF defense):** On `POST`/`PUT`/`PATCH`/`DELETE`, require `Sec-Fetch-Site: same-origin` (or `Origin` matching `http://localhost:<port>` / `http://127.0.0.1:<port>`).
  3. **Request body size cap:** Enforce a reasonable body limit (e.g., 64 KB on standard form routes, 10 MB strictly on the Step 10 statement-import route; `413 Payload Too Large` otherwise).
  4. **Security headers:** `Content-Security-Policy` (`default-src 'self'; script-src 'self'` with `@alpinejs/csp`, `style-src 'self' 'unsafe-inline'; frame-ancestors 'none'`), `X-Frame-Options: DENY`, `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`.
- [ ] **Tests:** `test/Api/SecuritySpec.hs` covering forged `Host`, cross-origin `POST`, oversized payloads, and CSP headers.

### Step 8 — SQLite WAL Concurrency, Single-Checkout Snapshots & Batched Reads (`H-6`, `M-2`, `M-5`) ✅ Core Concurrency Done (`c90b7cf`)
- [x] Fixed `src/Db/Pool.hs` & `app/Main.hs` (`c90b7cf`): `PRAGMA busy_timeout = 5000` **first** in `openConfigured` (wrapped in `bracketOnError`), single-stripe `setNumStripes (Just 1)` pool (`maxResources = 4`), one-time `PRAGMA journal_mode = WAL` + `wal_autocheckpoint = 1000` in `createPool`, `PRAGMA wal_checkpoint(TRUNCATE)` in `closePool`, and `bracket (createPool ...) closePool` in `Main.hs`.
- [x] Added `src/Db/Tx.hs` (`withImmediateTransaction` `BEGIN IMMEDIATE` + `withReadSnapshot` `BEGIN DEFERRED`, masked against async exceptions) across all write paths (`insertSpending`, `insertTransfer`, `withReplaceable`, `setTransactionCleared`, `reconcileAccountIfMatches`, `applyMigration`), tested in `Db.PoolSpec` and `Db.TxSpec` (227 passing tests).
- [x] Collapsed every `src/Api/*` handler (`Transactions`, `Budget`, `Categories`, `Accounts`) to **one `withConn` checkout per HTTP request** with `Db.Tx.withReadSnapshot` for consistent multi-table reads, and switched `localToday` / `resolveViewedMonth` to `IO`.
- [ ] *(Optional Step 12 cleanup items)*: Export `CorruptRow` & match `"categorized"` explicitly in `rowToTransaction`, and batch `fetchLines` in `Db.Transaction` if touching `Db.Transaction` during Step 12.

### Step 9 — Domain, Validation, Config & Schema Guardrails (`M-1`, `M-3`, `M-4`, `M-5`, `L-3`)
- [ ] *(Note: `TransferAmountMustBePositive` in `mkTransferPair`/`insertTransfer`/`updateTransfer`, `[1900, 2200]` year bounds in `mkYearMonth`/`parseIsoDate`, and trimmed/length-bounded `nonEmptyName`/`validatePayee` already landed in `9ae5492`!)* Complete remaining items: bound `splitEvenly`, and validate `BUCKTRACKER_PORT` (`1..65535`) + non-empty `BUCKTRACKER_DB_PATH` in `Config.hs`.
- [ ] Add `migrations/0002_import_index_and_constraints.sql` creating:
  - `CREATE UNIQUE INDEX idx_transactions_account_import_hash ON transactions (account_id, import_hash) WHERE import_hash IS NOT NULL;` (scoped per account so importing statements across multiple accounts never collides, while guaranteeing DB-level idempotency per account!).
  - Index on `assignments (year, month)`.

### Step 11 — Harden & Wire Online Backups (`H-3`, `DECISIONS.md` §7)
- [ ] Refactor `src/Db/Backup.hs` to step in bounded chunks (`100` pages) with brief backoff on contention, reject `destPath == sourcePath`, create parent directories, and write to `<destPath>.tmp` + atomic `renameFile`.
- [ ] Take an automatic pre-migration backup (`<dbDir>/backups/pre-migration-<timestamp>.db`) when pending migrations exist on a non-empty DB, and add a `POST /backups` UI button saving timestamped snapshots into `<dbDir>/backups/`.

### Step 12 — Test Suite Cleanup, Zero-Warning Build & GitHub Actions CI (`M-6`, `L-4`, `L-5`)
- [ ] Clean up leaked pools and temp `.db`/`.db-wal`/`.db-shm` files in `test/Api/Setup.hs` (`around` + `bracket`), replace `BSL8.unpack` with UTF-8 `Text` helpers, verify non-mutation on rejected POSTs, and expand `Domain.Gen` edge cases.
- [ ] Prune unused dependencies in `package.yaml`, resolve `-Worphans` cleanly, verify `stack test --ghc-options=-Werror` passes with **0 warnings**, and add `.github/workflows/ci.yml` (Windows + Ubuntu).
- [ ] **Track B Exit Gate:** Write `docs/handoffs/YYYY-MM-DD-phase-02-track-b.md` and tag **`v0.1.0`**!

---

## Track C — Bank Statement Import

**Goal:** Eliminate manual data-entry drudgery via CSV / CAMT.053 bank statement import, with deterministic deduplication so re-importing the same statement is always safe. Split out from the original Track B (2026-11-27 amendment above) so this sizable, self-contained feature gets its own review/merge unit instead of riding along with security and concurrency hardening. Does not block the `v0.1.0` tag — it may land before or after that tag.

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
- [ ] **Track C Exit Gate:** Write `docs/handoffs/YYYY-MM-DD-phase-02-track-c.md`. No version tag of its own — ships whenever it's ready, independent of `v0.1.0`.

---

## Track D — Scheduled Transactions & Cash-Flow Projections (`v0.2.0`, `DECISIONS.md` §10)

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
- [ ] Confirm `stack test --ghc-options=-Werror` is green; Carbon syncs `ARCHITECTURE.md`, `CHANGELOG.md` (`0.2.0.0`), `docs/handoffs/YYYY-MM-DD-phase-02-track-d.md`, and runs Architect Milestone Review #2 for `v0.2.0` sign-off.

---

## Track E — Recurring Obligations & Fixed Bills (`/recurring`, `DECISIONS.md` §13)

**Status:** Planned charter captured in [`docs/phases/track-e-recurring-spec.md`](track-e-recurring-spec.md); full turnkey engineering spec to be authored by Carbon after Tracks B–D complete.

### Core Scope Locked In
1. **Natural Category Placement + Orthogonal `is_fixed_obligation` Flag:** Every `recurring_rule` (`amount`, `cadence`: `Monthly | Quarterly | Annual`, `expected_day`, `target_category_id`) lands in its natural budget envelope (e.g., *Netflix*/*Crunchyroll* in *Entertainment*, *Basic-Fit* in *Sport*) so subscriptions compete directly with one-off purchases in that category, while `is_fixed_obligation :: Bool` distinguishes mandatory baseline bills (rent/mortgage, health insurance, utilities, internet, municipal/vehicle taxes) from discretionary subscriptions.
2. **Dedicated `/recurring` View & Monthly Baseline Summary:** Displays all recurring rules with derived monthly status (`Funded` / `Paid` / `Due`, matched via category activity/imports) and reports the **monthly mandatory fixed-obligation baseline** (including `1/3` quarterly and `1/12` annual integer-cent sinking-fund accruals) separately from **discretionary recurring subscriptions**.
3. **One-Click "Fund Recurring" Action:** Atomically and idempotently tops up each active recurring rule's target category `Assignment` for the active month (aggregating multiple rules targeting the same category) without manual data entry across 10+ rows.
