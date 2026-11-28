# Adversarial Security & Edge-Case Audit — Post-Track-A Snapshot

- **Date:** 2026-11-27
- **Reviewer:** Gemini (Architect)
- **Audited State:** Branch `feat/phase2-track-a-step5-register-completeness` (`bc63769` + uncommitted Step 6 edits in working tree)
- **Modules Audited:** `Domain/*`, `Db/*` (focus: `Db/Transaction.hs`, `Db/Pool.hs`, `Db/Category.hs`), `Api/*` (focus: `Api/Budget.hs`, `Api/Transactions.hs`, `Api/Categories.hs`, `Api/Accounts.hs`, `Api/Html.hs`), `static/app.js`, `static/alpine-csp.min.js`, `static/htmx.min.js`, `app/Main.hs`, `Config.hs`.

---

## Executive Summary

Track A Steps 1–5 (and in-progress Step 6) resolved the original MVP showstoppers cleanly: HTMX fragment swaps (`pageOrFragment`), `Api.Money`, inline `/budget` editing, dynamic `1..N` splits, live reconciliation preview, `<details>` drawers + shortcuts, transaction delete/edit, `?month=` navigation, local dates, and two-way archiving are all in place (including the `if (!this.editing) return;` double-submit fix and `/^\d+$/` JS parser tightening!).

However, an adversarial pass over **the new Step 4–6 code** uncovered **two critical new defects (`AUDIT-01`, `AUDIT-02`)**, **three high-severity data/race defects (`AUDIT-03`–`AUDIT-05`)**, and **three medium/CSP pitfalls (`AUDIT-06`–`AUDIT-08`)**. Below is the concrete, self-contained ticket queue for Claude's next session (finish uncommitted Step 6 → address `AUDIT-01..04` → execute [`docs/phases/track-b-spec.md`](../phases/track-b-spec.md)).

---

## Prioritized Ticket Checklist for Claude's Next Session

### `AUDIT-01` [CRITICAL — DoS / Infinite Loop] Bound `YearMonth` Years to Prevent 1.2-Billion-Month OOM & `maxBound` Non-Termination

- **Files:** `src/Domain/Types.hs:109-128, 144-155`, `src/Domain/Budget.hs:252-258`, `src/Domain/Error.hs`
- **Exploit / Failure Mechanics:**
  1. `GET /budget?month=99999999-01` (or `POST /budget/assign` with `assignMonth=99999999-01`) parses `YearMonth 99999999 1` via `parseYearMonth` → `mkYearMonth`, which only checks `1 <= m <= 12` and imposes **zero bound on `y`**.
  2. When any transaction exists in e.g. `2026-11`, `Domain.Budget.monthsThrough` runs `takeWhile (<= end) (iterate nextYearMonth start)` from `2026-11` to `99999999-01` — allocating and folding **~1.2 billion `MonthlyBudget` structs**, pegging CPU and OOM-crashing the server from a single `GET` request.
  3. Worse: `?month=9223372036854775807-12` (`maxBound :: Int`) causes `nextYearMonth (YearMonth maxBound 12)` to wrap `maxBound + 1` to `minBound`, which remains `<= end` forever — an **infinite non-terminating loop**.
  4. Years outside `0000..9999` also break ISO-8601 `TEXT` range comparisons (`WHERE date >= ? AND date < ?`) in `Db.Transaction.listTransactionsInMonth`.
- **Actionable Fix:**
  - [ ] Add `InvalidYear Int` to `DomainError` and require `1900 <= y && y <= 2200` in `mkYearMonth` (and in `Api.Transactions.parseIsoDate`!).
  - [ ] Add a QuickCheck / unit test verifying `parseYearMonth "99999999-01" == Nothing` and `GET /budget?month=99999999-01` falls back safely to `localToday`'s month.

---

### `AUDIT-02` [CRITICAL — Reconciliation Lock Bypass] Deleting or Editing an Unreconciled Transfer Leg Destroys Its `Reconciled` Counterpart Leg

- **Files:** `src/Db/Transaction.hs:388-413, 447-462`, `src/Api/Transactions.hs:688-717`
- **Failure Mechanics:**
  Suppose €500 is transferred from Checking (`Leg A`, `txId = 10`) to Savings (`Leg B`, `txId = 11`). Checking is reconciled (`Leg A = Reconciled`), while Savings is not yet reconciled (`Leg B = Uncleared` or `Cleared`).
  1. `withReplaceable` (`Db/Transaction.hs:406-412`) checks `txStatus tx == Reconciled` **only on the target row (`Leg B`)**, never checking the sibling row sharing `transfer_id`!
  2. Calling `deleteTransaction` or `updateTransfer` on `Leg B` executes `DELETE FROM transactions WHERE transfer_id = ?` (`line 391`), **silently deleting Checking's `Reconciled` transaction** and corrupting Checking's reconciled balance!
  3. Even when neither leg is `Reconciled` (e.g., `Leg A = Cleared`, `Leg B = Uncleared`), `updateTransfer` (`line 462`) passes `(txStatus tx)` to `insertTransferRows`, **clobbering the counterpart leg's independent `Cleared` status**!
  4. In `Api.Transactions` (`lines 689, 704`), `editControls` and `deleteButton` render `Edit` and `Delete` controls on `Leg B` even when `Leg A` is `Reconciled`.
- **Actionable Fix:**
  - [ ] In `Db.Transaction.withReplaceable`, when `tx` is `TransferLeg transferId _ _`, query **all** rows with `WHERE transfer_id = ?`: if **any** leg has `txStatus == Reconciled`, return `Left CannotModifyReconciledTransaction`!
  - [ ] In `updateTransfer` / `insertTransferRows`, preserve `(fromLegStatus, toLegStatus)` individually when replacing the two legs (matching each account to its prior leg's status if the account pair didn't change, or defaulting any newly swapped account side to `Uncleared`).
  - [ ] Pass the transfer's counterpart leg status (or reconciled `Set TransferId`) to `editControls` / `deleteButton` in `Api.Transactions` (note: if Checking was reconciled in October and Savings' leg is viewed, checking DB or loading counterpart status ensures UI consistency).
  - [ ] Add regression test in `Db.TransactionSpec`: reconcile `fromAcc` only, attempt `deleteTransaction` and `updateTransfer` via `toLeg`'s `txId`, assert `Left CannotModifyReconciledTransaction` and both legs untouched.

---

### `AUDIT-03` [HIGH — Data Loss & Cross-Kind Overwrite] `update*` Erases `txImportHash`, Allows Cross-Kind Mutation & Truncates Mismatched Split Arrays

- **Files:** `src/Db/Transaction.hs:417-462`, `src/Api/Transactions.hs:224-285, 328-338`
- **Failure Mechanics:**
  1. **`txImportHash` wiped on edit (`Db/Transaction.hs:421, 440`):** `updateInflow` and `updateSpending` pass `Nothing` instead of preserving `txImportHash tx`! Once Track C (ABN AMRO import) lands, editing an imported transaction's payee or splitting an imported supermarket purchase across two categories will erase its `import_hash`, causing the next overlapping bank statement import to re-import a duplicate!
  2. **Cross-kind overwrite (`Db/Transaction.hs:417-462`):** Posting `POST /transactions/:id/edit-inflow` where `:id` is actually a `TransferLeg` or `Categorized` transaction deletes the split/transfer (both legs!) and replaces it with an `Inflow` because `updateInflow` / `updateSpending` / `updateTransfer` never check that `txCategorization tx` matches the expected kind!
  3. **Archived reassignment on edit (`Api/Transactions.hs:225, 277, 329`):** While editing rightly permits keeping the transaction's *existing* archived account/category, a crafted POST to `edit-*` can move a transaction onto a *different*, newly chosen archived account or category.
  4. **Silent `zip` truncation (`Api/Transactions.hs:247`):** `zip (spendingLineCategoryIds form) (spendingLineAmounts form)` silently drops unmatched elements if a POST submits unequal counts of `lineCategoryId` and `lineAmount`.
- **Actionable Fix:**
  - [ ] Preserve `importHash` on `updateInflow` and `updateSpending` when `accId == txAccount tx` (`let preservedHash = if accId == txAccount tx then txImportHash tx else Nothing`).
  - [ ] Add `TransactionKindMismatch` to `DomainError` and verify `txCategorization tx` matches `Inflow` / `Categorized` / `TransferLeg` inside `updateInflow` / `updateSpending` / `updateTransfer`.
  - [ ] On `edit*Handler`, reject archived accounts/categories *unless* that ID was already attached to the existing transaction before the edit.
  - [ ] Reject `NewSpendingForm` when `length (spendingLineCategoryIds form) /= length (spendingLineAmounts form)`.

---

### `AUDIT-04` [HIGH — Stranded Future Funds in Step 6] `archiveCategoryHandler` Ignores Future Months & `archiveAccountHandler` Ignores `Uncleared` Items

- **Files:** `src/Api/Categories.hs:129-166`, `src/Api/Accounts.hs:98-106` (currently uncommitted Step 6 work)
- **Failure Mechanics:**
  1. `currentlyAvailable` (`Api/Categories.hs:153-166`) folds `rolloverMonths` through `monthsThrough ym assignments txs` (which reaches the latest future assignment/transaction month `end`), **but only checks `budgetFor ym budgets` (today's month)!** If a category has `€0.00` available today (`2026-11`) and `+€400.00` assigned next month (`2026-12`, reachable via `?month=2026-12`), `archiveCategoryHandler` allows archiving it — and `Api.Budget.assignHandler` (`line 113`) then blocks editing archived categories, stranding €400.00 in December!
  2. `archiveAccountHandler` (`Api/Accounts.hs:101-106`) checks `accountBalance aid txs /= zeroCents`, allowing an account with offsetting `+€100` (`Cleared`) and `-€100` (`Uncleared`) transactions to be archived — after which `reconcileCell` (`line 236`) hides the Reconcile form permanently while un-reconciled rows remain on the account.
- **Actionable Fix:**
  - [ ] Block `archiveCategoryHandler` if `available /= zeroCents` in **any** folded month `>= ym` (or if any future month `> ym` has non-zero assignment/activity on `cid`).
  - [ ] Block `archiveAccountHandler` if `accountBalance aid txs /= zeroCents` **or** `any ((/= Reconciled) . txStatus) txs` (or allow reconciling archived accounts until all rows are `Reconciled` — pick one and document in `ARCHITECTURE.md`).

---

### `AUDIT-05` [HIGH — Race Conditions / Double-Click Duplication] Read-Before-Transaction TOCTOU in `withReplaceable` & `reconcileAccount`

- **Files:** `src/Db/Transaction.hs:188, 237, 366, 403-413`, `src/Api/Accounts.hs:122-146`
- **Failure Mechanics:**
  1. **Double-click Edit duplicates transactions:** In `withReplaceable` (`Db/Transaction.hs:406-412`), `maybeTx <- getTransaction conn txId'` runs **outside** `withTransaction`. Two concurrent `POST /transactions/:id/edit-spending` requests both read `Just tx`, then sequentially run `DELETE` (second `DELETE` affects 0 rows!) + `insertSpendingRows` — **turning one expense into two identical expenses**!
  2. **Reconcile TOCTOU:** `reconcileAccountHandler` computes `clearedBalance` on connection #2 and then runs `UPDATE transactions SET status = 'reconciled' WHERE account_id = ? AND status = 'cleared'` on connection #3 without re-verifying the sum inside the write transaction.
- **Actionable Fix:** Execute as specified in [`docs/phases/track-b-spec.md` §1.3–1.4](../phases/track-b-spec.md) (`withImmediateTransaction` wrapping both the precondition read and the write on a single connection).

---

### `AUDIT-06` [MEDIUM — Alpine CSP Injection Pattern & Split Clone Quirk]

- **Files:** `src/Api/Budget.hs:231`, `src/Api/Transactions.hs:595-604`, `static/app.js:56-60, 105-112`
- **Failure Mechanics:**
  1. **Dynamic string interpolation in `x-data` (`Api/Budget.hs:231`):** `xData_ ("inlineAssign('" <> displayText <> "')")` is safe *only* because `centsToEuroText` emits `[0-9.-]`. Because browsers decode HTML character references (`&#39;` → `'`) *before* Alpine's `getAttribute('x-data')` runs its AST parser (`static/alpine-csp.min.js`), copying this pattern onto any user-controlled field (`accName`, `catName`, `txPayee`) enables breaking out of `'...'` into Alpine CSP's expression evaluator.
  2. **Archived category leak on `editSpendingForm` clone (`static/app.js:107`):** When editing an old split whose last line uses a since-archived category (`categoryChoices` appends `"(archived)"` to that row's `<select>`), clicking `+ Add split line` calls `lines.lastElementChild.cloneNode(true)`, cloning that `(archived)` option into new split lines (and leaving the HTML `value="..."` attribute on the cloned amount input).
- **Actionable Fix:**
  - [ ] Refactor `assignedCell` to `xData_ "inlineAssign()"` + `data-initial-value` (`this.$el.dataset.initialValue` in `init()`, matching `reconcileCalc`). Add rule to `CLAUDE.md`: *never interpolate dynamic values into `x-*` attributes; pass server data via `data-*` attributes*.
  - [ ] In `splitEditor.addLine()` (`static/app.js`), also call `amountInput.removeAttribute('value')` and strip any `<option>` marked `data-archived-extra` on cloned rows.

---

### `AUDIT-07` [MEDIUM — Strict CSP Blockers in `Api.Html` & `htmx.min.js`]

- **Files:** `src/Api/Html.hs:46, 128-132`, `static/htmx.min.js`
- **Failure Mechanics:** Track B's strict `style-src 'self'` header will block:
  1. `Api.Html.page`'s inline `<style>` element (`style_ pageStyle`).
  2. `htmx.min.js`'s default `includeIndicatorStyles: true` boot-time `<style>` injection into `<head>`.
- **Actionable Fix:** Follow [`docs/phases/track-b-spec.md` §2.2 Layer C](../phases/track-b-spec.md): move `pageStyle` + `.htmx-indicator` + `[x-cloak]` into `/static/app.css` and add `<meta name="htmx-config" content='{"includeIndicatorStyles":false}'>` to `Api.Html.page`.

---

### `AUDIT-08` [LOW — Domain/Validation Trim & Transfer Sign Guard]

- **Files:** `src/Domain/Validation.hs:16-19`, `src/Domain/Transaction.hs:109`, `src/Db/Transaction.hs:234, 454`
- **Actionable Fix:**
  - [ ] Make `nonEmptyName` return `Right (Text.strip name)` with max length `<= 80` and no control chars, and validate `payee` length (`<= 160`, no control chars).
  - [ ] Enforce `amount > zeroCents` (`TransferAmountMustBePositive`) inside `Domain.Transaction.mkTransferPair`, `Db.Transaction.insertTransfer`, and `Db.Transaction.updateTransfer` (defense-in-depth beneath `Api.Money.parsePositiveEuros`).
