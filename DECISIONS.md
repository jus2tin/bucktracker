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
| Frontend | Servant + Lucid + HTMX + Pico CSS + Alpine.js — server-rendered semantic HTML with locally vendored static assets (`/static/*`), no npm/JS build step (updated ahead of Phase 2, see §12). |
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

## 8. External review backlog (Gemini review, 2026-11-26)

An external review (`GEMINI_REVIEW.md`, written by Gemini, not by us) was
read and independently checked against the actual code before acting on
it — not taken at face value, since a review from one model is exactly as
fallible as code from another. Checking involved reading the relevant
source, and in a few cases compiling and running a small standalone
repro rather than reasoning from memory. Full detail (locations, exact
remediation code) lives in the conversation that did this triage, not
repeated here — this section is the durable pointer back to it.

**Fixed immediately** (both verified as real; see §3/§5 for why they
matter):
- Server bound to all network interfaces (`0.0.0.0`) instead of
  loopback only, contradicting the no-auth/"localhost only" assumption
  in §2 — confirmed by reading Warp's own source (`defaultSettings`'
  host is `"*4"`). Fixed in `app/Main.hs` via `runSettings` +
  `setHost "127.0.0.1"`.
- `Db.Transaction.insertSpending` didn't check that the account is
  on-budget, so a `Categorized` transaction on a `Tracking` account
  would silently break invariant 1 (its activity would count toward
  `categoryActivity`/`available`, but the account's balance is excluded
  from `onBudgetBalanceTotal`). Fixed: `insertSpending` now rejects this
  with `CategorizedTransactionRequiresOnBudgetAccount`, and
  `Domain.Budget.categoryActivity` got the same on-budget filter
  `accountInflows` already had, as defense-in-depth. Regression test
  added in `Db.TransactionSpec`.

**One claim checked and found wrong:** the review said an empty
`BUCKTRACKER_DB_PATH` "crashes inside `createDirectoryIfMissing True
(takeDirectory "")`" — compiled and ran exactly that: `takeDirectory ""`
returns `"."`, no crash. (The underlying point — nothing rejects an
empty path — still stands, see M-9 below.)

**Deferred, not forgotten** — real or plausible, lower urgency than the
two above (mostly because the HTTP surface they need doesn't exist yet,
e.g. there's no Categories/Transactions UI to reach them through).
Verification depth varies: items marked *(confirmed)* were checked
against the code or reproduced; the rest are plausible on inspection but
not individually re-derived.

- **H-1.** No CSRF/`Host`/`Origin` protection on the mutating endpoints.
  Matters more now that the server used to be LAN-reachable (fixed
  above), but cross-origin requests to `127.0.0.1` from a malicious page
  in the browser are still a real concern even loopback-only.
- **H-2.** HTMX loads from a CDN with no SRI hash, and there are no
  security headers (`CSP`, `X-Frame-Options`, etc.). The CDN dependency
  itself is already a documented v0.1 tradeoff (`Api.Html`); the missing
  SRI/headers are the new part.
- **H-3.** *(confirmed)* `Db.Pool.openConfigured` sets `busy_timeout`
  *after* `journal_mode=WAL`/`foreign_keys`; `withTransaction`'s
  deferred `BEGIN` can hit `SQLITE_BUSY` immediately on a write-upgrade
  without waiting for `busy_timeout`; and the `PRAGMA foreign_keys = ON`
  inside `migrations/0001_initial.sql` is a documented SQLite no-op
  because `applyMigration` runs it inside a transaction (harmless today
  only because `openConfigured`/`Db.Setup` already set it per-connection
  beforehand).
- **H-4.** *(Fixed 2026-11-27 — see §9.)* *(confirmed, reproduced)* `Db.Migrations.applyMigration`
  reads `.sql` files with `Data.Text.IO.readFile`, which decodes using
  the system locale encoding, not UTF-8. On this machine that's
  `CP850`; reading the "§" in `migrations/0001_initial.sql`'s own header
  comment silently produces two different, wrong characters instead.
  Harmless today (it's inside a `--` comment) but will corrupt any
  future migration with meaningful non-ASCII content. Same bug family
  as the stdout encoding crash already fixed in `Main.hs` — that fix
  didn't cover file reads.
- **H-5.** *(Rollover-orchestrator half fixed 2026-11-27 — see §9; the
  archive/cascade half below is still open.)* `archiveAccount`/
  `archiveCategory` don't check for a zero balance, don't block new
  transactions/assignments against an archived entity, and
  `archiveCategoryGroup` doesn't cascade to its categories. ~~Also,
  there's no multi-month rollover orchestrator in `Domain.Budget` yet
  (something that folds `nextCarriedIn`/`rolloverRtaAdjustment`
  month-to-month) — `budgetBalancesAccounts` is only ever exercised
  single-month, with `carriedIn = zeroCents`, in `BudgetSpec` today.~~
- **H-6.** `Db.Backup.backupTo` copies in one `backupStep (-1)` call,
  which (for a large db) holds the lock for the whole backup rather than
  yielding between chunks — in tension with its own "doesn't lock out
  writers" docstring. Also: no atomic temp-file-then-rename (a failed
  backup can leave a half-written file and destroys any previous backup
  at that path), and no guard against `destPath == sourcePath`.
- **M-1.** `negate (minBound :: Int64) == minBound` (two's-complement
  wraparound) — `negateCents`/`scaleCents` have no bounds checking.
  `splitEvenly` also has no bound on `n` (memory use is `O(n)`).
- **M-2.** `mkTransferPair`/`insertTransfer` don't reject `amount <= 0`.
- **M-3.** `insertTransfer`'s account lookups run outside the write
  transaction (TOCTOU window), and `CorruptRow`/`UnknownAccount` are
  thrown as unexported `IO` exceptions rather than surfaced as
  `DomainError` — a caller can't catch `UnknownAccount` to return a 404.
- **M-4.** N+1 queries in `listTransactionsForAccount`/
  `listTransactionsInMonth` (one `fetchLines` call per categorized
  transaction); no shared read-transaction across that initial query and
  the follow-ups; `rowToTransaction`'s wildcard branch treats any
  unrecognized `kind` as `"categorized"` instead of matching the literal
  — currently inert because the DB `CHECK` constraint already limits
  `kind` to the three known values, but worth tightening for clarity.
- **M-5.** `mkYearMonth` doesn't bound the year, and
  `listTransactionsInMonth`'s `date >= ? AND date < ?` text comparison
  only sorts correctly for 4-digit years (a 5-digit year would compare
  as "less than" a 4-digit one as plain text).
- **M-6.** `nonEmptyName` validates against the *stripped* name but
  stores the *unstripped* one (so `"  Checking  "` is stored verbatim);
  no max length anywhere.
- **M-7.** Several `Api.Accounts` HTTP-semantics nitpicks: the form has
  no `method_ "post"`/`action_` fallback for when HTMX fails to load;
  validation errors return `200 OK` instead of a 4xx; archiving an
  unknown or already-archived ID is a silent no-op; no `hx-confirm` on
  archiving; `createAccountHandler`/`archiveAccountHandler` each check
  out a pool connection twice (once for the write, once inside
  `renderFragment`'s re-read) instead of once.
- **M-8.** No graceful shutdown (`Main` never calls `closePool`); if
  `runMigrations` throws inside `Db.Pool.createPool`, the pool it just
  made is never destroyed; `openConfigured` doesn't close the connection
  if a `PRAGMA` call fails after `open`.
- **M-9.** `BUCKTRACKER_PORT` has no `1..65535` range check;
  `BUCKTRACKER_DB_PATH` uses `str` instead of `nonempty`, so an
  explicitly-empty value passes config parsing. (The specific crash
  claimed for the empty-path case was checked and is wrong — see above —
  but the missing validation itself is real.)
- ~~**M-10.** `Account`/`CategoryGroup`/`Category` export their raw data
  constructors, so code outside `Domain` can build one bypassing
  `mkAccount`/`mkCategory` (unlike `YearMonth`, which hides its
  constructor on purpose). Also, `DECISIONS.md` §3 names reconciliation
  as in-scope for v0.1, but `Domain.Budget` only has `accountBalance`
  (all statuses combined) — no `clearedBalance`/reconciliation function
  exists yet.~~ *(Fixed 2026-11-27 — see §9.)*
- **L-2.** The "Categories" nav link in `Api.Html` points at `/categories`,
  which isn't mounted yet — a dead link until that page exists (next on
  the roadmap anyway).
- **L-3.** The schema could use a few more defense-in-depth `CHECK`
  constraints (same-account transfer legs, non-zero transfer amount,
  non-blank names, a sane year range on `assignments`, a partial unique
  index on `import_hash`).
- **L-6.** `README.md` is still just a title (no setup instructions/env
  vars documented); `stack.yaml`'s snapshot is a raw GitHub URL rather
  than the equivalent `snapshot: lts-24.68` shorthand (mitigated today
  by `stack.yaml.lock`).
- **Test suite gaps**, mostly a consequence of the above not being fixed
  yet rather than independent bugs: invariant 1 is never tested across
  multiple months; `Domain.Gen`'s `genCents`/`genDayIn` are bounded in
  ways that hide the `Int64`/calendar edge cases above by construction;
  `genWorld` never generates a `Tracking -> Tracking` transfer and gives
  every transfer `TransferId 0` before renumbering (only `txId` gets
  renumbered); `Api.AccountsSpec` checks status codes/error text more
  often than actual persisted state (e.g. the "without adding a row"
  tests don't re-query to confirm); `bodyContains` in that spec decodes
  the response body as Latin-1 (`BSL8.unpack`), which would mismatch a
  genuine multi-byte UTF-8 comparison (harmless today since all current
  fixture strings are ASCII); `Api.Setup`/`Db.PoolSpec`'s temp
  files/pools are never cleaned up after a test run.

**Discarded** (checked and found to not apply, so deliberately left out
above): the English-only violation finding — true when the review was
written, resolved by the translation pass earlier in this project's
history; the unused-dependency/orphan-instance warnings — not a finding,
an already-documented deliberate Phase 3 tradeoff (§1, §6, and the
comments in `package.yaml`); the missing WAL-sidecar `.gitignore`
patterns — fixed directly instead of deferred.

## 9. Product-owner prioritization (2026-11-27): backlog items pulled forward

Product direction (reviewed against this file and the actual code, same
discipline as §8): keep v0.1's scope exactly as set in §4 — no
forecasting yet — but pull four specific §8 backlog items forward ahead
of finishing the Budget UI, "so real data entry doesn't hit preventable
bugs". All four are now fixed; all 82 tests pass (`stack test`).

- **H-4 (UTF-8 migration reading).** `Db.Migrations.applyMigration` now
  reads each migration file as raw bytes (`Data.ByteString.readFile`)
  and decodes them explicitly with `decodeUtf8'`, instead of
  `Data.Text.IO.readFile`'s locale-dependent decoding. A bad decode
  throws a new typed `InvalidMigrationEncoding` exception (same pattern
  as `Db.Transaction.CorruptRow`) rather than silently mis-decoding.
  Both `applyMigration` and the exception are now exported so
  `Db.MigrationsSpec` can regression-test the encoding directly: a
  file with multi-byte UTF-8 content applies cleanly, and a file that
  isn't valid UTF-8 is rejected instead of silently accepted.
- **M-10a (sealed constructors).** `Account`/`CategoryGroup`/`Category`
  no longer export their raw data constructors — `Domain.Account`/
  `Domain.Category` now export the types and their field accessors
  separately (the `YearMonth` pattern). The only ways to build one from
  outside are `mkAccount`/`mkCategoryGroup`/`mkCategory` (validating) or
  the new `unsafeReconstructAccount`/`unsafeReconstructCategoryGroup`/
  `unsafeReconstructCategory` (deliberately named for grep-ability: for
  `Db.Account`/`Db.Category`'s `FromRow` instances and insert functions
  to rebuild a value from data that's already valid, without
  re-validating a name on every read). `Domain.Budget`/`Domain.Gen` were
  updated to import explicit field accessors instead of the now-gone
  wildcard constructor import.
- **M-10b (reconciliation).** `Domain.Budget.clearedBalance` sums only
  `Cleared`/`Reconciled` transactions for an account (excluding
  `Uncleared`), matching the "pure comparison" reconciliation design
  already described in §3 — the caller still does
  `clearedBalance aid txs == bankStatementBalance` itself; this
  deliberately isn't a separate domain type. Two new QuickCheck
  properties in `BudgetSpec`.
- **H-5 (multi-month rollover orchestrator).** `Domain.Budget` gained
  `MonthlyBudget` and `rolloverMonths`, which fold the month rollover
  (`nextCarriedIn` per category, plus `rolloverRtaAdjustment` into the
  next month's Ready-to-Assign carry-in) across a whole ascending
  sequence of months, instead of every month starting at `zeroCents`.
  `Domain.Gen` gained `MultiMonthWorld`/`genMultiMonthWorld` (several
  consecutive months, same accounts/categories throughout), and
  `BudgetSpec` gained a property test asserting invariant 1
  (`budgetBalancesAccounts`'s equation) holds at *every* month in the
  sequence, not just a single isolated one.
  - **Also wired into `Api.Budget`**, not just left as unused Domain
    code: the Budget page now reads the *entire* assignment/transaction
    history (`Db.Assignment.listAllAssignments`,
    `Db.Transaction.listAllTransactions`, both new) and folds
    `rolloverMonths` from the earliest month with any activity through
    the current one, picking out the current month's `MonthlyBudget`
    for display. The page still has no month picker (unchanged
    simplification, consistent with `Api.Transactions`), but its carry
    and Ready-to-Assign figures are no longer always zero going into a
    new month.
  - The archive/zero-balance/cascade half of the original H-5 entry is
    **not** part of this fix and remains open (see §8 above).

## 10. Post-v0.1 roadmap: scheduled transactions & projections

Confirmed as a core v0.2+ requirement (product direction, 2026-11-27):
forecasting and scheduled bills, promoted out of the generic "recurring
transactions" line in §4's out-of-scope list into an explicit design,
decided now so v0.1's ledger isn't built in a way that has to be undone
later.

- **The real ledger stays strictly historical/present-tense.** No
  future or hypothetical row is ever inserted into `transactions`,
  `transaction_lines`, or `assignments` — a forecast is a *view*, never
  a write. All 5 invariants in §5 keep holding over actual cash exactly
  as they do today; nothing about `Domain.Transaction`/`Domain.Budget`
  changes to accommodate this.
- **Recurrence gets its own storage, separate from the ledger.**
  Scheduled bills, recurring expenses and expected income live in a new
  `scheduled_items` table (recurrence rule + category/account + amount
  template), not in `transactions`. A scheduled item is a *template*;
  it only ever produces a real transaction when the user actually
  confirms/enters one (manually, or — much later — via a "confirm
  today's scheduled items" action). It never auto-inserts into the real
  ledger on its own.
- **Projections are a pure simulation, not a new persisted state.**
  `Domain.Projection` (new module, same purity rules as the rest of
  `Domain/`: no `IO`, no DB) expands each `ScheduledItem`'s recurrence
  rule into synthetic future events and folds them forward month by
  month, reusing `rolloverCategoryMonth`/`available` (§3, now also
  `rolloverMonths`, §9) exactly as the real ledger does — a projected
  month is computed with the *same* rollover function as a real one,
  just fed synthetic activity instead of real transactions. Shape:
  `project :: World -> [ScheduledItem] -> YearMonth -> ProjectedWorld`,
  where `World` is the real present-day state (accounts, categories,
  assignments, transactions — closely related to `Domain.Gen.World`,
  though that's currently test-only) and `ProjectedWorld` carries the
  simulated `MonthlyBudget`s from the current month through the target
  month. Never touches the database.
- **UI: a separate `/forecast` page**, not a mode of `/budget`. Shows
  projected category balances, a cash-flow runway, and a savings
  trajectory, built from `Domain.Projection`'s pure output. `/budget`
  itself stays exactly as strict as it is today — no scheduled item or
  projected number ever appears there, so the envelope page a user
  budgets from never mixes real and hypothetical money.
- **Not yet decided** (left for when this phase actually starts):
  the exact recurrence-rule representation (RFC 5545-style vs. a
  simpler fixed set of patterns), whether `ScheduledItem` needs its own
  soft-delete/pause state, and how far into the future `/forecast`
  defaults to projecting.

## 11. Flagged for v0.1 completion (not yet fixed)

- **Archiving is a one-way trip.** `archiveAccount`/`archiveCategory`/
  `archiveCategoryGroup` only ever set `archived_at` — there's no
  "unarchive" function anywhere in `Db.*`, and no UI control for one.
  Combined with there being no confirmation step before archiving
  anything (M-7 above already named this for `Api.Accounts`
  specifically; it's equally true of `Api.Categories` and category
  groups, which M-7 doesn't mention), one accidental click on "Archive"
  is effectively permanent today — the only way back is a direct SQL
  `UPDATE ... SET archived_at = NULL`.
  - Flagged 2026-11-27 (product direction, found while reviewing the
    Categories page): before calling v0.1 done, add (a) an
    `hx-confirm` "Are you sure?" prompt on every archive button across
    Accounts/Categories/category groups, and (b) a real unarchive
    action — a new `Db.*` function clearing `archived_at`, plus the UI
    control to trigger it — so a mistaken archive has an actual undo
    path, not just a confirmation gate in front of the same one-way
    door.
  - Deliberately **not fixed in this pass** — logged so it isn't lost,
    not yet acted on.

## 12. Phase 2 decisions: Frontend & UX foundation, inline editing & bank import (2026-11-27)

Decided at the start of Product Phase 2 (after the MVP adversarial
review, `docs/reviews/2026-11-27-mvp-adversarial-review.md`) to turn
Bucktracker into a fast, pleasant daily driver without compromising the
zero-build-step, minimal-dependency, server-truthful architecture.

### Static asset serving (vendored, zero build step)
- **Delivery:** Static assets (`pico.min.css`, `htmx.min.js`,
  `alpine.min.js` / `alpine-csp.min.js`, and a small local `app.js` if
  needed) are checked into `static/`, listed under Cabal `data-files` in
  `package.yaml` (the exact same mechanism already proven for
  `migrations/*.sql`), located at runtime via
  `Paths_bucktracker.getDataDir`, and served by Servant at `/static/*`
  via `"static" :> Raw` (`Servant.Server.StaticFiles.serveDirectoryWebApp`,
  already included in `servant-server`).
- **Why:** Eliminates the v0.1 `unpkg.com` CDN dependency (`Api.Html`),
  makes Bucktracker work **100% offline**, removes third-party network
  calls from a personal finance app, and still requires **no Node, npm,
  bundler, or asset pipeline**.

### Low-level semantic CSS: Pico CSS (`pico.min.css`)
- **Choice:** Adopt [Pico CSS](https://picocss.com/) (`pico.min.css`),
  targeting semantic HTML elements (`<header>`, `<nav>`, `<main>`,
  `<table>`, `<form>`, `<fieldset>`, `<dialog>`) inside a standard
  `.container` wrapper.
- **Why:** Gives clean typography, spacing, form/table styling, native
  `<dialog>` modals, responsive layout, and automatic light/dark mode
  (`prefers-color-scheme`) immediately, while keeping Haskell/Lucid
  templates clean and free of Tailwind/Bootstrap utility-class noise.

### Low-level client-side JS: Alpine.js (strictly ephemeral micro-interactions)
- **Choice:** Add Alpine.js alongside HTMX **strictly** for local,
  ephemeral UI state that should not require a server round-trip:
  1. **Dynamic split-transaction editor:** Adding/removing split lines
     (`1..N`) in the DOM and live-displaying unallocated remaining cents
     before form submission (unlocking the arbitrary-length
     `NonEmpty TransactionLine` that `Domain.Transaction` and
     `Db.Transaction` already support).
  2. **Live reconciliation math:** Computing
     `Cleared Balance − Statement Balance = Remaining Difference` live
     as the user types their bank statement balance.
  3. **Inline edit toggles, `<dialog>` modals/drawers & keyboard
     shortcuts:** Opening/closing quick-entry `<dialog>` modals or
     drawers and handling keyboard shortcuts (e.g. `n` for new
     transaction, `Escape` to cancel/close).
- **Hard architectural boundary (non-negotiable):**
  - **Server remains the sole source of truth.** HTMX + Servant + Lucid
    still own all data fetching, persistence, validation, and canonical
    HTML rendering. Alpine never owns persistent application state or
    client-side routing.
  - **No floating-point money in JS either.** Any client-side preview
    arithmetic (split remainder, reconciliation difference) must parse
    euro strings into whole integer cents first — never `parseFloat`
    addition — and the Haskell `Domain`/`Db` layer still validates and
    computes every persisted cent independently.
  - **CSP compatibility:** Prefer `@alpinejs/csp` (`alpine-csp.min.js`)
    with named `Alpine.data(...)` components in `/static/app.js` so
    `Content-Security-Policy` can enforce `script-src 'self'` without
    `'unsafe-eval'`. If standard `alpine.min.js` is used instead,
    `'unsafe-eval'` in `script-src 'self' 'unsafe-eval'` must be
    documented as an explicit local-only tradeoff (with external script
    origins still completely blocked).

### High-impact daily UX workflows promoted into Phase 2
- **Inline cell editing on `/budget`:** Clicking directly on a
  category's `Assigned` cell switches it to an inline `<input>` (Alpine
  toggle) that saves via HTMX on `Enter` / `change` (`Escape` cancels)
  and swaps `#budget-content`, replacing the detached top-of-page
  assignment form as the primary budgeting interaction.
- **Bank statement import (CSV & CAMT.053):** Promoted from §4's
  out-of-scope list into Phase 2, leveraging `transactions.import_hash`:
  - Pure parsers in `Domain.Import` for **CAMT.053** (ISO 20022 XML,
    standard across Dutch/EU banks) and **CSV** (configurable/preset
    delimiters and `.`/`,` decimals).
  - Deterministic `ImportHash` scoped per account (`UNIQUE (account_id,
    import_hash) WHERE import_hash IS NOT NULL`), incorporating the
    within-statement occurrence index of identical `(date, amount,
    payee/ref)` tuples so two legitimate identical purchases on the same
    day are preserved while re-importing the same file is 100%
    idempotent.
  - **Two-step Import Preview → Commit UI (`/import`):** Because
    Invariant 5 forbids uncategorized expenses in `transactions`, file
    upload first renders a pure preview table flagging duplicates and
    letting the user pick categories/transfers/inflows before committing
    selected rows atomically (`Cleared` by default).
