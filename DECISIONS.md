# Bucktracker — Decisions

This document records the decisions made before the code was written.
Where a decision turned out to have a subtlety that wasn't explicitly
discussed, it's noted as an "Implementation note" directly under the
relevant decision — not a silent deviation, but something to confirm/
revisit later.

## 1. Toolchain & repo

- **Resolver:** `lts-24.68` (GHC 9.10.3). The original CLAUDE.md mentioned
  GHC 9.14.2 — that was inconsistent with `stack.yaml` and not installed;
  this has been corrected.
- **License:** MIT (`LICENSE` and `package.yaml` updated).
- **`src/Lib.hs`:** removed now that `src/Domain/` is in place.
- **Compiler flags:** `-Wall -Wmissing-export-lists -Wunused-packages`
  (plus the other standard `stack new` warnings). `-Werror` is
  **CI-only**, not in `package.yaml` itself (see §6).

## 2. Technical choices

| Area | Choice |
|---|---|
| Database | SQLite via `sqlite-simple`, hand-written numbered `.sql` migrations, explicit `FromRow`/`ToRow` (no TemplateHaskell, no `persistent`/`beam`). |
| Frontend | Servant + Lucid + HTMX, server-rendered, no npm/JS build step. |
| Auth | None in v0.1 (localhost-only). Does use `ReaderT AppEnv Handler` + `hoistServer` so handlers are testable without starting a real server. |
| Config | Env vars. Defaults: port `8080`, DB path `%APPDATA%\bucktracker\bucktracker.db` on Windows — the path is configurable so a later Linux port (`$XDG_DATA_HOME` / `~/.local/share/bucktracker/bucktracker.db`) is trivial. |
| IDs | `newtype` around `Int64`, auto-increment from SQLite (`rowid`). UUID only where dedup is needed later (import). |
| Currency | EUR only, in `Cents` (`Int64`). No `Currency` field in v0.1. |
| Tests | `hspec` + `QuickCheck` for `Domain/`, in-memory SQLite for `Db/` (phase 2), `hspec-wai` for `Api/` (phase 3). |

## 3. Domain rules (the YNAB engine)

### Accounts
- `AccountType = Checking | Savings | Cash | Tracking`. On-budget =
  anything except `Tracking`.
- An opening balance is **not a field** on `Account`, but an `Inflow`
  transaction on that account (see "Transactions" below) — just like in
  YNAB, that amount flows straight into Ready to Assign.

### Categories & months
- Two levels: `CategoryGroup -> Category`.
- The period is always a calendar month (`YearMonth`).
- **Month rollover (crucial):** a positive category balance (`available`)
  carries forward unchanged into the next month. A negative balance
  (overspending) resets the category to 0 and the whole shortfall is
  deducted from Ready to Assign. Implemented in
  `Domain.Budget.rolloverCategoryMonth`, with the core invariant that no
  money is created or lost during that transition:
  `rolloverCarry <> rolloverRtaAdjustment == available cm` always holds
  (hard-tested, see `BudgetSpec`).

### Transactions & splits
- Amounts: expenses negative, income positive, in `Cents`. A transaction
  has **three** possible "destinations", modeled as one closed sum type,
  `Categorization`:
  1. `Categorized (NonEmpty TransactionLine)` — a normal expense/income,
     split across one or more categories. `NonEmpty` guarantees at the
     type level that a categorized transaction can never exist "without
     lines" — this enforces invariant 5 ("exactly one category or a
     split") at compile time, no runtime check needed.
  2. `Inflow Cents` — flows straight into Ready to Assign, with no
     category. **Implementation note:** this is the explicit exception
     to "every non-transfer transaction has a category" — income and the
     opening balance *are*, by definition, uncategorized money that still
     needs to be allocated. That's exactly how YNAB treats "Inflow: Ready
     to Assign", and it matches the opening-balance decision above.
  3. `TransferLeg TransferId AccountId Cents` — the other side of a
     transfer; touches no category and no Ready to Assign.
- **Splits sum to exactly the total by construction**
  (`transactionAmount` derives the total from the lines instead of
  storing and validating it separately) — invariant 3 is therefore
  impossible to violate, not just "tested".
- **Transfers:** two linked `Transaction` legs sharing a `TransferId`.
  One leg is literally `negateCents` of the other (`mkTransferPair`), so
  invariant 2 (sum = 0) is also a construction guarantee. The only
  validation: the two accounts must differ
  (`TransferRequiresDistinctAccounts`).
  - **Implementation note / known v0.1 limitation:** the invariant "sum
    of on-budget account balances = categories + Ready to Assign" only
    holds as long as (a) `Categorized` transactions live exclusively on
    on-budget accounts, and (b) a transfer never connects an on-budget
    account with a tracking account (otherwise money disappears from the
    on-budget side without the budget side seeing it, or vice versa).
    Neither rule was **yet** enforced as a runtime `DomainError` in
    Phase 1, because `Transaction`/`mkTransferPair` on its own has no way
    to know whether an `AccountId` is on-budget (that's aggregate
    knowledge). This became a validation in the assembly/service layer
    once `Db`/`Api` existed (phase 2/3) — until then it was a documented
    assumption, and the property tests deliberately generate only "valid
    worlds" (see `Domain.Gen.genWorld`) to demonstrate this.
- **Import dedup:** every `Transaction` has an optional
  `txImportHash :: Maybe ImportHash` (still unused in v0.1, for a later
  CSV/CAMT.053 import phase).

### Status & payees
- `TransactionStatus = Uncleared | Cleared | Reconciled`.
- Reconciliation is a pure comparison
  (`clearedBalance == bankStatementBalance`), not a separate domain type
  — the caller (eventually `Api`) decides what to do with a mismatch.
- In v0.1, payee is just `Text` on the transaction, no separate
  table/entity.

## 4. Scope v0.1 (MVP)

**In scope:** accounts (on-budget & tracking), category groups +
categories, manual transactions (incl. splits & transfers), monthly
budget with rollover/overspending reset, reconciliation, Lucid+HTMX UI.

**Out of scope (later):** credit-card envelope logic, targets/goals,
recurring transactions, CSV/CAMT.053 import (the hash column is already
in place), reporting.

## 5. Invariants (hard-tested with QuickCheck in Phase 1)

1. Sum of all on-budget account balances = sum of all category balances +
   Ready to Assign. → `Domain.Budget.budgetBalancesAccounts`,
   `BudgetSpec`, within the v0.1 limitation noted in §3 (no mixed
   on-budget/tracking transfers, categorization only on on-budget
   accounts).
2. Every transfer sums to 0 across its two legs. → construction
   guarantee in `mkTransferPair`, tested in `TransactionSpec`.
3. Split lines sum exactly to the transaction total. → construction
   guarantee (`transactionAmount` derives, doesn't validate), tested in
   `TransactionSpec`.
4. Per month: available = assigned + carried over from the previous
   month + activity (activity is already *signed*: expenses negative —
   this is equivalent to "... − expenses" with expenses as a positive
   amount, but written consistently in code as one signed `Cents`
   addition to avoid a separate plus/minus distinction). →
   `Domain.Budget.available`, and the matching conservation law at the
   month rollover
   (`rolloverCarry <> rolloverRtaAdjustment == available cm`) in
   `BudgetSpec`.
5. No transaction without an account; every non-transfer transaction has
   exactly one category (or is a split). → `txAccount` is a required
   field (type level), `Categorized` uses `NonEmpty` (type level); the
   explicit `Inflow` exception is described above.

## 6. Open items from Phase 1 — now decided in §7, or deliberately deferred

- **`-Werror` in CI:** once `Db/`/`Api/` actually use the dependencies
  already listed in `package.yaml` (`sqlite-simple`, `servant*`, `warp`,
  `lucid`, …), the current `-Wunused-packages` warnings on the `library`
  component disappear. Only enable `-Werror` in CI after that happens (or
  add dependencies per phase instead of all at once), otherwise every CI
  run on phase 1 would fail. (Moot for now anyway: CI itself is deferred
  until after the MVP, see §7.)
- **On-budget/tracking transfer validation** (see §3): decided in §7 —
  now, in phase 2.
- **CI pipeline:** decided in §7 — deliberately *not* now, only after the
  MVP (see §4 for that MVP's scope).
- **Backup strategy** for the SQLite file: decided in §7.

## 7. Phase 2 decisions (Db layer)

Interviewed ahead of phase 2. Per item: the choice and the reason.

| Area | Choice | Reason |
|---|---|---|
| Migration delivery | Cabal `data-files` + `Paths_bucktracker` (`getDataFileName`) | Stay plain, reviewable `.sql` files; no TemplateHaskell; cabal/stack installs them automatically. |
| Migration runner | Auto-apply on startup, tracked in a `schema_migrations` table | Simple for a single-user app; no separate command to remember or forget. |
| DB connection management | A real connection pool (`resource-pool`) | A deliberate choice against the "one connection + lock" recommendation — see the note under the table. |
| SQLite pragmas | `journal_mode=WAL`, `foreign_keys=ON`, `busy_timeout` | Better concurrency (relevant now that there's a pool), FKs are actually enforced, no immediate "database is locked" errors. |
| `YearMonth` storage | Two columns `year INTEGER, month INTEGER` | No parse step, trivial to sort/filter, 1-to-1 with `ymYear`/`ymMonth`. |
| Deleting accounts/categories | Soft delete (`archived_at`/`closed` column) | Historical transactions stay consistent; no cascade-delete hassle. |
| Transfer validation (on-budget/tracking) | Becomes a real `DomainError` now, in Phase 2 | The Db/repository layer can look up accounts when storing a transfer; prevents an inconsistent ledger from ever being persisted. |
| Loading config | A config library (`envparse`) | Structured validation/error messages for env vars, instead of manual `lookupEnv`. |
| Db test strategy | A fresh `:memory:` connection per test, migrations run over it each time | Full test isolation; slightly more overhead per test, but no chance of tests affecting each other. |
| CI pipeline | **Not now** — set up only after the MVP (see §4) | Build out the MVP first; CI gets added once there's a stable whole to guard. (Decision revisited during the Phase 2 interview: originally "now", changed to "after MVP".) |
| Backup strategy | SQLite's online backup API, from within the app itself | More robust than a plain file copy, and consistent even while in use; a bit more code than a `.bak` copy. |

**Implementation note — DB connection management:** a pool has little
benefit for *writes* on a single-user SQLite db (SQLite is single-writer
regardless), but it does help with concurrent *reads* (e.g. multiple open
browser tabs/HTMX requests) without every request having to wait on a
writing transaction — especially with WAL mode, which doesn't let readers
be blocked by an active writer. `resource-pool` with a small maximum (e.g.
4-8 connections) is the library used for this in Phase 2.
