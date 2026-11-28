# Adversarial Security & Edge-Case Audit — Post-Track-A Snapshot

- **Date:** 2026-11-27 *(Resolution verified: 2026-11-28)*
- **Reviewer:** Carbon / Gemini (Architect)
- **Audited State:** Branch `feat/phase2-track-a-step5-register-completeness` (`bc63769` + uncommitted Step 6 edits in working tree)
- **Resolution Commits:** `c599309` (`AUDIT-04`) and `9ae5492` (`AUDIT-01..03`, `AUDIT-05..08`) — **All 8 tickets resolved (222 passing tests, 0 regressions)**
- **Modules Audited:** `Domain/*`, `Db/*` (focus: `Db/Transaction.hs`, `Db/Pool.hs`, `Db/Category.hs`), `Api/*` (focus: `Api/Budget.hs`, `Api/Transactions.hs`, `Api/Categories.hs`, `Api/Accounts.hs`, `Api/Html.hs`), `static/app.js`, `static/app.css`, `static/alpine-csp.min.js`, `static/htmx.min.js`, `app/Main.hs`, `Config.hs`.

---

## Resolution Sign-Off Summary (2026-11-28)

Commits `c599309` and `9ae5492` cleanly closed all eight post-Track-A findings (`AUDIT-01`..`AUDIT-08`) with full unit/QuickCheck/WAI regression coverage (222 passing examples) and introduced zero new invariant or CSP regressions.

**Track B Follow-Through Notes (already specified in [`docs/phases/track-b-spec.md`](../phases/track-b-spec.md)):**
1. **`BEGIN IMMEDIATE` & Single-Checkout Handlers (Track B Step 8):** `9ae5492` moved precondition reads inside `sqlite-simple`'s `withTransaction` (`withReplaceable`, `reconcileAccountIfMatches`), eliminating the read-outside-transaction race on a single connection. Upgrading `withTransaction` (`BEGIN DEFERRED`) to `withImmediateTransaction` (`BEGIN IMMEDIATE`), setting `poolSize = 1` / `busy_timeout = 5000`, and collapsing multi-`withConn` handlers (such as `edit*Handler`'s pre-check `getTransaction`) remain scheduled in `track-b-spec.md` §1.2–1.4.
2. **Minor Test & Error-Message Polish (Track B Step 12, non-blocking):** Add a 3-line `GET /static/app.css` check in `test/Api/StaticSpec.hs`, and optionally surface specific `NameTooLong` / `InvalidCharacters` banner messages in `Api.Accounts` / `Api.Categories` (currently mapped safely to `"Could not create ..."`).

---

## Executive Summary

Track A Steps 1–5 (and in-progress Step 6) resolved the original MVP showstoppers cleanly: HTMX fragment swaps (`pageOrFragment`), `Api.Money`, inline `/budget` editing, dynamic `1..N` splits, live reconciliation preview, `<details>` drawers + shortcuts, transaction delete/edit, `?month=` navigation, local dates, and two-way archiving are all in place (including the `if (!this.editing) return;` double-submit fix and `/^\d+$/` JS parser tightening!).

However, an adversarial pass over **the new Step 4–6 code** uncovered **two critical new defects (`AUDIT-01`, `AUDIT-02`)**, **three high-severity data/race defects (`AUDIT-03`–`AUDIT-05`)**, and **three medium/CSP pitfalls (`AUDIT-06`–`AUDIT-08`)**. Below is the concrete, self-contained ticket queue and verification record.

---

## Prioritized Ticket Checklist & Verification Record

### `AUDIT-01` [CRITICAL — DoS / Infinite Loop] Bound `YearMonth` Years to Prevent 1.2-Billion-Month OOM & `maxBound` Non-Termination — ✅ RESOLVED (`9ae5492`)

- **Files:** `src/Domain/Types.hs:109-128, 144-155`, `src/Domain/Budget.hs:252-258`, `src/Domain/Error.hs`
- **Exploit / Failure Mechanics:**
  1. `GET /budget?month=99999999-01` (or `POST /budget/assign` with `assignMonth=99999999-01`) parses `YearMonth 99999999 1` via `parseYearMonth` → `mkYearMonth`, which only checks `1 <= m <= 12` and imposes **zero bound on `y`**.
  2. When any transaction exists in e.g. `2026-11`, `Domain.Budget.monthsThrough` runs `takeWhile (<= end) (iterate nextYearMonth start)` from `2026-11` to `99999999-01` — allocating and folding **~1.2 billion `MonthlyBudget` structs**, pegging CPU and OOM-crashing the server from a single `GET` request.
  3. Worse: `?month=9223372036854775807-12` (`maxBound :: Int`) causes `nextYearMonth (YearMonth maxBound 12)` to wrap `maxBound + 1` to `minBound`, which remains `<= end` forever — an **infinite non-terminating loop**.
  4. Years outside `0000..9999` also break ISO-8601 `TEXT` range comparisons (`WHERE date >= ? AND date < ?`) in `Db.Transaction.listTransactionsInMonth`.
- **Actionable Fix & Verification (`9ae5492`):**
  - [x] Added `InvalidYear Int` to `DomainError` and enforced `1900 <= y && y <= 2200` in both `Domain.Types.mkYearMonth` and `Api.Transactions.parseIsoDate` (preventing out-of-range transaction dates from entering `dayToYearMonth` / `monthsThrough`).
  - [x] Verified via QuickCheck & unit tests in `Domain.TypesSpec` (`maxBound`, `minBound`, `1899-12`, `2201-01`, `99999999-01`), `Api.BudgetSpec`, and `Api.TransactionsSpec`.

---

### `AUDIT-02` [CRITICAL — Reconciliation Lock Bypass] Deleting or Editing an Unreconciled Transfer Leg Destroys Its `Reconciled` Counterpart Leg — ✅ RESOLVED (`9ae5492`)

- **Files:** `src/Db/Transaction.hs:388-413, 447-462`, `src/Api/Transactions.hs:688-717`
- **Failure Mechanics:**
  Suppose €500 is transferred from Checking (`Leg A`, `txId = 10`) to Savings (`Leg B`, `txId = 11`). Checking is reconciled (`Leg A = Reconciled`), while Savings is not yet reconciled (`Leg B = Uncleared` or `Cleared`).
  1. `withReplaceable` (`Db/Transaction.hs:406-412`) checks `txStatus tx == Reconciled` **only on the target row (`Leg B`)**, never checking the sibling row sharing `transfer_id`!
  2. Calling `deleteTransaction` or `updateTransfer` on `Leg B` executes `DELETE FROM transactions WHERE transfer_id = ?` (`line 391`), **silently deleting Checking's `Reconciled` transaction** and corrupting Checking's reconciled balance!
  3. Even when neither leg is `Reconciled` (e.g., `Leg A = Cleared`, `Leg B = Uncleared`), `updateTransfer` (`line 462`) passes `(txStatus tx)` to `insertTransferRows`, **clobbering the counterpart leg's independent `Cleared` status**!
  4. In `Api.Transactions` (`lines 689, 704`), `editControls` and `deleteButton` render `Edit` and `Delete` controls on `Leg B` even when `Leg A` is `Reconciled`.
- **Actionable Fix & Verification (`9ae5492`):**
  - [x] `Db.Transaction.withReplaceable` queries `transferSiblingsOf` (`WHERE transfer_id = ? AND id != ?`) inside `withTransaction` and returns `Left CannotModifyReconciledTransaction` if **any** leg is `Reconciled`.
  - [x] `Db.Transaction.updateTransfer` / `insertTransferRows` preserves `(statusForAccount fromAccId, statusForAccount toAccId)` individually when replacing the two legs (defaulting any newly swapped account side to `Uncleared`).
  - [x] `Api.Transactions.isLockedTransaction` checks the full month's unfiltered `transactionsInMonth` (since paired transfer legs share `txDate`), hiding `Edit` and `Delete` even when `?account=<id>` filters out the reconciled sibling.
  - [x] Regression tests verified in `Db.TransactionSpec` and `Api.TransactionsSpec`.

---

### `AUDIT-03` [HIGH — Data Loss & Cross-Kind Overwrite] `update*` Erases `txImportHash`, Allows Cross-Kind Mutation & Truncates Mismatched Split Arrays — ✅ RESOLVED (`9ae5492`)

- **Files:** `src/Db/Transaction.hs:417-462`, `src/Api/Transactions.hs:224-285, 328-338`
- **Failure Mechanics:**
  1. **`txImportHash` wiped on edit (`Db/Transaction.hs:421, 440`):** `updateInflow` and `updateSpending` pass `Nothing` instead of preserving `txImportHash tx`! Once Track C (ABN AMRO import) lands, editing an imported transaction's payee or splitting an imported supermarket purchase across two categories will erase its `import_hash`, causing the next overlapping bank statement import to re-import a duplicate!
  2. **Cross-kind overwrite (`Db/Transaction.hs:417-462`):** Posting `POST /transactions/:id/edit-inflow` where `:id` is actually a `TransferLeg` or `Categorized` transaction deletes the split/transfer (both legs!) and replaces it with an `Inflow` because `updateInflow` / `updateSpending` / `updateTransfer` never check that `txCategorization tx` matches the expected kind!
  3. **Archived reassignment on edit (`Api/Transactions.hs:225, 277, 329`):** While editing rightly permits keeping the transaction's *existing* archived account/category, a crafted POST to `edit-*` can move a transaction onto a *different*, newly chosen archived account or category.
  4. **Silent `zip` truncation (`Api/Transactions.hs:247`):** `zip (spendingLineCategoryIds form) (spendingLineAmounts form)` silently drops unmatched elements if a POST submits unequal counts of `lineCategoryId` and `lineAmount`.
- **Actionable Fix & Verification (`9ae5492`):**
  - [x] `Db.Transaction.preservedImportHash` preserves `txImportHash` on `updateInflow` and `updateSpending` when `newAccId == txAccount tx` (and clears it on cross-account moves).
  - [x] Added `TransactionKindMismatch` to `DomainError` and enforced `expectInflow` / `expectCategorized` / `expectTransferLeg` inside `withReplaceable` before deleting rows.
  - [x] Added `movesOntoArchivedAccount`, `movesOntoArchivedCategory`, and `movesOntoArchivedTransferAccount` in `Api.Transactions` to block moving onto any archived entity not already attached prior to the edit.
  - [x] Rejected `NewSpendingForm` in `withValidSpending` when `length (spendingLineCategoryIds form) /= length (spendingLineAmounts form)`.

---

### `AUDIT-04` [HIGH — Stranded Future Funds in Step 6] `archiveCategoryHandler` Ignores Future Months & `archiveAccountHandler` Ignores `Uncleared` Items — ✅ RESOLVED (`c599309`)

- **Files:** `src/Api/Categories.hs:129-166`, `src/Api/Accounts.hs:98-106`
- **Failure Mechanics:**
  1. `currentlyAvailable` (`Api/Categories.hs:153-166`) folds `rolloverMonths` through `monthsThrough ym assignments txs` (which reaches the latest future assignment/transaction month `end`), **but only checks `budgetFor ym budgets` (today's month)!** If a category has `€0.00` available today (`2026-11`) and `+€400.00` assigned next month (`2026-12`, reachable via `?month=2026-12`), `archiveCategoryHandler` allows archiving it — and `Api.Budget.assignHandler` (`line 113`) then blocks editing archived categories, stranding €400.00 in December!
  2. `archiveAccountHandler` (`Api/Accounts.hs:101-106`) checks `accountBalance aid txs /= zeroCents`, allowing an account with offsetting `+€100` (`Cleared`) and `-€100` (`Uncleared`) transactions to be archived — after which `reconcileCell` (`line 236`) hides the Reconcile form permanently while un-reconciled rows remain on the account.
- **Actionable Fix & Verification (`c599309`):**
  - [x] Replaced single-month check with `hasNonZeroBalanceFromNowOn` in `Api.Categories`, blocking `archiveCategoryHandler` if `available /= zeroCents` in **any** folded month `>= ym` (verified in `Api.CategoriesSpec`).
  - [x] Blocked `archiveAccountHandler` when `accountBalance aid txs /= zeroCents` **or** `any ((/= Reconciled) . txStatus) txs` (verified in `Api.AccountsSpec` and documented in `ARCHITECTURE.md`).

---

### `AUDIT-05` [HIGH — Race Conditions / Double-Click Duplication] Read-Before-Transaction TOCTOU in `withReplaceable` & `reconcileAccount` — ✅ RESOLVED (`9ae5492`; `BEGIN IMMEDIATE` upgrade tracked in Track B Step 8)

- **Files:** `src/Db/Transaction.hs:188, 237, 366, 403-413`, `src/Api/Accounts.hs:122-146`
- **Failure Mechanics:**
  1. **Double-click Edit duplicates transactions:** In `withReplaceable` (`Db/Transaction.hs:406-412`), `maybeTx <- getTransaction conn txId'` runs **outside** `withTransaction`. Two concurrent `POST /transactions/:id/edit-spending` requests both read `Just tx`, then sequentially run `DELETE` (second `DELETE` affects 0 rows!) + `insertSpendingRows` — **turning one expense into two identical expenses**!
  2. **Reconcile TOCTOU:** `reconcileAccountHandler` computes `clearedBalance` on connection #2 and then runs `UPDATE transactions SET status = 'reconciled' WHERE account_id = ? AND status = 'cleared'` on connection #3 without re-verifying the sum inside the write transaction.
- **Actionable Fix & Verification (`9ae5492`):**
  - [x] Moved `getTransaction` and `transferSiblingsOf` inside `withTransaction conn` in `Db.Transaction.withReplaceable`, and added `Db.Transaction.reconcileAccountIfMatches` (atomically checking `clearedBalance == statementBalance` and executing `UPDATE` inside one `withTransaction conn`), wired into `Api.Accounts.reconcileAccountHandler` and tested in `Db.TransactionSpec`. *(Full `BEGIN IMMEDIATE` / `poolSize = 1` write serialization follows in [`docs/phases/track-b-spec.md` §1.2–1.4](../phases/track-b-spec.md).)*

---

### `AUDIT-06` [MEDIUM — Alpine CSP Injection Pattern & Split Clone Quirk] — ✅ RESOLVED (`9ae5492`)

- **Files:** `src/Api/Budget.hs:231`, `src/Api/Transactions.hs:595-604`, `static/app.js:56-60, 105-112`
- **Failure Mechanics:**
  1. **Dynamic string interpolation in `x-data` (`Api/Budget.hs:231`):** `xData_ ("inlineAssign('" <> displayText <> "')")` is safe *only* because `centsToEuroText` emits `[0-9.-]`. Because browsers decode HTML character references (`&#39;` → `'`) *before* Alpine's `getAttribute('x-data')` runs its AST parser (`static/alpine-csp.min.js`), copying this pattern onto any user-controlled field (`accName`, `catName`, `txPayee`) enables breaking out of `'...'` into Alpine CSP's expression evaluator.
  2. **Archived category leak on `editSpendingForm` clone (`static/app.js:107`):** When editing an old split whose last line uses a since-archived category (`categoryChoices` appends `"(archived)"` to that row's `<select>`), clicking `+ Add split line` calls `lines.lastElementChild.cloneNode(true)`, cloning that `(archived)` option into new split lines (and leaving the HTML `value="..."` attribute on the cloned amount input).
- **Actionable Fix & Verification (`9ae5492`):**
  - [x] Refactored `Api.Budget.assignedCell` to `xData_ "inlineAssign()"` + `data-initial-value` (`this.$el.dataset.initialValue` in `static/app.js`), documented the `data-*`-only Alpine CSP rule in `ARCHITECTURE.md` and `docs/phases/phase-02-hardening-and-forecasting.md`.
  - [x] Marked archived `<option>` elements with `data-archived-extra` in `Api.Transactions.categoryOption` and updated `splitEditor.addLine()` (`static/app.js`) to strip `option[data-archived-extra]`, reset `selectedIndex = 0`, and call `amountInput.removeAttribute('value')`.

---

### `AUDIT-07` [MEDIUM — Strict CSP Blockers in `Api.Html` & `htmx.min.js`] — ✅ RESOLVED (`9ae5492`)

- **Files:** `src/Api/Html.hs:46, 128-132`, `static/htmx.min.js`, `static/app.css`
- **Failure Mechanics:** Track B's strict `style-src 'self'` header will block:
  1. `Api.Html.page`'s inline `<style>` element (`style_ pageStyle`).
  2. `htmx.min.js`'s default `includeIndicatorStyles: true` boot-time `<style>` injection into `<head>`.
- **Actionable Fix & Verification (`9ae5492`):**
  - [x] Extracted `pageStyle` + `.htmx-indicator` + `[x-cloak]` into `static/app.css`, linked `/static/app.css` in `Api.Html.page`, removed inline `style_`, and added `<meta name="htmx-config" content='{"includeIndicatorStyles":false}'>` per [`docs/phases/track-b-spec.md` §2.2 Layer C](../phases/track-b-spec.md).

---

### `AUDIT-08` [LOW — Domain/Validation Trim & Transfer Sign Guard] — ✅ RESOLVED (`9ae5492`)

- **Files:** `src/Domain/Validation.hs:16-19`, `src/Domain/Transaction.hs:109`, `src/Db/Transaction.hs:234, 454`
- **Actionable Fix & Verification (`9ae5492`):**
  - [x] Updated `Domain.Validation.nonEmptyName` (`Text.strip`, `<= 80` chars, no control chars) and added `validatePayee` (`Text.strip`, `<= 160` chars, no control chars), wired into `Api.Transactions` and verified in `Domain.ValidationSpec` & `Api.TransactionsSpec`.
  - [x] Enforced `amount > zeroCents` (`TransferAmountMustBePositive`) inside `Domain.Transaction.mkTransferPair`, `Db.Transaction.insertTransfer`, and `Db.Transaction.updateTransfer` (verified in `Db.TransactionSpec`).
