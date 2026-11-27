# Bucktracker — Architecture (the Owner's Manual)

This is the plain-English tour: how a click in the browser turns into a
row in SQLite and back, and how the budgeting math actually works. It
deliberately skips Haskell syntax trivia — read the code itself for
that, with `DECISIONS.md` for *why* each choice was made. This file is
for *how it fits together* and *where to go to change something*.

If you only read one section, make it
["Where do I change X?"](#where-do-i-change-x) — it's the fastest way
back into this codebase after time away from it.

## The shape of it

Three layers, each only allowed to know about the one below it:

```
 Browser (HTMX)
      |  HTML form POST / GET
      v
 src/Api/     <- Servant routes + handlers. HTTP in, HTML out. Thin.
      |  calls into
      v
 src/Domain/  <- Pure business logic. No IO, no SQL, no HTTP. The
      |           actual "budgeting app" lives here.
      | (Api also calls Db directly for persistence — Domain never does)
      v
 src/Db/      <- SQLite queries. Talks to Domain's types, never the
                  other way around.
```

The rule that matters: **`Domain/` never imports `Api/` or `Db/`.** You
can read and understand the entire budgeting engine (`src/Domain/`)
without a database or a web server in the picture at all — which is
exactly how it's tested (`test/Domain/`, pure QuickCheck properties, no
I/O whatsoever). `Api/` is the only layer that talks to *both* `Domain/`
and `Db/`; it glues them together for one HTTP request and otherwise
does as little as possible itself.

There's a fourth, much smaller piece: `app/Main.hs` wires up config,
opens the connection pool, and starts the Warp web server. It's the
only place that "boots" anything.

## Request lifecycle: clicking "Add expense"

Concretely, here's everything that happens when someone on the
Transactions page fills in the spending form and clicks submit.

1. **Browser → HTMX.** The form has
   `hx-post="/transactions/spending" hx-target="#transactions-content"
   hx-swap="outerHTML"`. HTMX intercepts the submit, sends a perfectly
   ordinary form POST to that URL, and — this is the only "magic" HTMX
   does — takes whatever HTML comes back and swaps it into
   `#transactions-content` instead of letting the browser navigate to a
   new page. No JSON, no client-side framework, no build step.

2. **Servant routes it.** `src/Api/Transactions.hs` declares
   `"transactions" :> "spending" :> ReqBody '[FormUrlEncoded]
   NewSpendingForm :> Post '[HTML] (Html ())`. Servant matches the URL
   and method, then decodes the raw form fields (all plain `Text`) into
   a `NewSpendingForm` record via `FromForm` — matched by the HTML
   `name="..."` attributes, nothing fancier.

3. **The handler does HTTP-shaped validation.**
   `createSpendingHandler` turns the form's `Text` fields into real
   types: an `AccountId`, a `CategoryId`, a `Day`, a `Cents` amount —
   using small total parsers (`parseAccountId`, `parseEuros`,
   `parseIsoDate`; never `Prelude.read`, which can crash on bad input).
   It also checks the account and category actually exist. Anything
   wrong here (unknown account, "not a number" in the amount field)
   short-circuits straight to an error message — the database is never
   touched.

4. **The Db layer does the real write.** The handler calls
   `Db.insertSpending` (`src/Db/Transaction.hs`), which runs inside one
   SQLite transaction: it builds a `Domain.Transaction.TransactionLine`
   and assembles a real `Transaction` via
   `Domain.Transaction.mkSpendingTransaction`, checks the account is
   on-budget (rejecting with the `DomainError`
   `CategorizedTransactionRequiresOnBudgetAccount` if not — see
   "Illegal states, unrepresentable" below), and only then runs the
   `INSERT`s into `transactions` and `transaction_lines`.

5. **Success re-renders the fragment.** `renderFragment` re-reads the
   current month's accounts/categories/transactions straight back out
   of `Db.*` and builds the updated `#transactions-content` `Html ()`
   value with ordinary Lucid combinators (`table_`, `tr_`, `td_`, …) —
   there's no diffing or templating language, it's just Haskell
   building a tree of HTML.

6. **Servant serializes it, HTMX swaps it in.** `servant-lucid`'s
   `MimeRender` instance turns that `Html ()` into the HTTP response
   body. HTMX receives the 200 and replaces `#transactions-content` —
   the new expense's row appears, with no full page reload.

Every other page (`Api.Accounts`, `Api.Categories`, `Api.Budget`) is
the exact same shape: parse the form → ask `Domain`/`Db` to do the real
work → re-render the same fragment on success *or* on a validation
error (so the error banner and the unchanged table render together,
not a separate error page).

## Illegal states, unrepresentable

A theme worth naming explicitly, because it explains a lot of
`Domain/`'s shape: wherever possible, the types make a wrong value
impossible to *construct*, rather than validating it after the fact.

- A split transaction's lines are a `NonEmpty TransactionLine` — "a
  split with zero lines" doesn't typecheck, so there's nothing to
  validate.
- A transfer's total is never stored at all — it's *derived* as the
  sum of its lines (`transactionAmount`), so a split can never drift
  from its total because there's no separate total to drift from.
- IDs are `newtype`s around `Int64` (`AccountId`, `CategoryId`, …) so
  you can't accidentally pass a `CategoryId` where an `AccountId` is
  expected — that's a compile error, not a 3 a.m. production bug.
- `Account`/`CategoryGroup`/`Category`/`YearMonth` don't export their
  raw constructors at all. The only way to build one from outside
  `Domain/` is through a smart constructor (`mkAccount`,
  `mkYearMonth`, …) that validates as it goes, or — for the `Db` layer
  reading already-valid data back out of storage — a clearly-named
  `unsafeReconstructAccount`-style function that skips validation on
  purpose and says so in its name.

Where a rule genuinely can't be enforced by the type alone (e.g. "the
two legs of a transfer must be on different accounts"), it's a
`DomainError` — a plain value in a closed `Either`, in
`src/Domain/Error.hs` — never an exception, never a silent default.

## The Money Engine

This is the part that makes Bucktracker a budgeting app and not just a
transaction log. All of it lives in `src/Domain/Budget.hs`, and all of
it is pure — no database, no dates-are-actually-"today" assumptions,
just functions from numbers to numbers. Every example below uses real
euro amounts so the formulas are concrete, not abstract.

### Ready to Assign

Money doesn't belong to a category until you put it there. When income
arrives, it's an `Inflow` transaction — not categorized, not yet
"spent on" anything — and it flows straight into **Ready to Assign**
(RTA): the pool of unassigned money.

> Say your salary of **€2,000** lands in Checking in November, and
> you haven't assigned anything yet: **Ready to Assign = €2,000.**
> You then assign €200 to Groceries and €50 to Dining Out. Those two
> amounts leave the pool: **Ready to Assign = €2,000 − €200 − €50 =
> €1,750.**

That's exactly `Domain.Budget.readyToAssign`:

```
readyToAssign rtaCarriedIn accounts month assignments txs =
  rtaCarriedIn <> accountInflows accounts month txs <> negateCents (assignedTotal month assignments)
```

`rtaCarriedIn` is what's left over from *previous* months — see
rollover below.

### CategoryMonth and the rollover

Every category, every month, has one `CategoryMonth`: how much was
**assigned**, how much **activity** it saw (signed — a €40 grocery
run is `-€40`), and how much was **carried in** from the month before.
Its `available` balance is just the three added together:

```
available cm = carriedIn <> assigned <> activity
```

> **Groceries, November:** assigned €200, spent €150 (activity
> `-€150`), nothing carried in yet (first month). Available =
> €0 + €200 − €150 = **€50 left over.**

At the turn of the month, `rolloverCategoryMonth` decides what happens
to that €50 — and this is the one rule every envelope-budgeting app
lives or dies by:

- **If available ≥ 0** (you didn't overspend): the whole amount
  **carries forward unchanged** into next month's `carriedIn`, and
  Ready to Assign is untouched.
  > Groceries' €50 becomes **December's `carriedIn` for Groceries** —
  > it's still "Groceries money", not lumped back into Ready to
  > Assign.
- **If available < 0** (you overspent): the category resets to **€0**
  — it can't carry a debt forward — and the *entire shortfall* is
  deducted from Ready to Assign instead.
  > **Dining Out, November:** assigned €50, spent €80 (activity
  > `-€80`). Available = €0 + €50 − €80 = **−€30.** December's
  > `carriedIn` for Dining Out is **€0**, and that **−€30** comes
  > straight out of Ready to Assign — so overspending in one envelope
  > is never invisible; it's always paid for by *some* money,
  > immediately.

Either way, **no money is created or destroyed** — `rolloverCarry <>
rolloverRtaAdjustment == available` always holds, and it's
QuickCheck-tested, not just asserted in a comment.

Doing this for one month is easy; doing it correctly across *many*
consecutive months — where this month's carry depends on last month's
rollover, which depends on the month before that — is what
`Domain.Budget.rolloverMonths` does: it folds the whole chain forward,
month by month, so the Budget page's numbers are correct no matter how
long the ledger's history is, not just in the first month anyone ever
used the app.

### Split transactions

A single receipt can touch more than one category — a supermarket run
that's both groceries and household supplies, say:

> A **€64.30** receipt, split as **€40.00 → Groceries** and **€24.30
> → Household Supplies.**

The transaction's total isn't a separate field that could drift out of
sync with its lines — it's *computed* as their sum
(`transactionAmount`). €40.00 + €24.30 is mathematically always
€64.30; there's no code path where a split's lines could add up to
something other than its total, because there's no second number to
disagree with them.

### Zero-sum transfers

Moving your own money between your own accounts — Checking to Savings,
say — isn't income and it isn't an expense, so it must never touch a
category or Ready to Assign. A transfer is two `Transaction` rows
sharing one `TransferId`:

> Moving **€300** from Checking to Savings: Checking gets a leg of
> **−€300**, Savings gets a leg of **+€300.**

`mkTransferPair` builds the second leg as the literal `negateCents` of
the first — there's no way to construct a transfer whose two legs
don't sum to zero, because the second leg's value *is* "the first
leg's value, negated", not an independently-chosen number.

### Reconciliation

Reconciling against a bank statement is nothing more exciting than a
comparison: `clearedBalance` sums every transaction on an account that
the bank has already shown you (status `Cleared` or `Reconciled`) —
deliberately ignoring anything still `Uncleared` (money that's left
your side but the bank hasn't posted yet, like a pending card charge).

> Your bank statement says Checking has **€1,245.67**. If
> `clearedBalance` for Checking also comes out to **€1,245.67**, the
> account reconciles. If it doesn't, something's missing, duplicated,
> or on the wrong account — and now you know to go look, instead of
> silently trusting a number that was already wrong.

There's deliberately no separate "Reconciliation" type or table —
reconciling is just `clearedBalance aid txs == bankStatementBalance`,
decided by whoever's looking at the two numbers. In the UI this is two
small, separate steps: the Transactions page has a "Clear"/"Unclear"
button per row (`Domain.Types.toggleCleared`) so you can mark what the
bank has actually shown you so far; the Accounts page then has a
one-field "Reconcile" form per account that compares `clearedBalance`
to whatever you type in. On a match, `Db.Transaction.reconcileAccount`
locks every `Cleared` transaction on that account in as `Reconciled`;
on a mismatch, nothing is written at all — you get both numbers back
to go find the missing, duplicate, or still-uncleared transaction
yourself.

## Where do I change X?

| I want to... | Touch these files |
|---|---|
| Add a field to `Account` (or `Category`/`CategoryGroup`) | New numbered file in `migrations/` (the column); `src/Domain/Account.hs` (the field, `mkAccount`, `unsafeReconstructAccount`); `src/Db/Field.hs` if it's a new scalar type; `src/Db/Account.hs` (the `FromRow` instance and every `SELECT`/`INSERT`); `src/Api/Accounts.hs` (the form field and the HTML table column) |
| Change what happens at month rollover (e.g. partial carry, a cap) | `src/Domain/Budget.hs` (`rolloverCategoryMonth`, `rolloverMonths`); `test/Domain/BudgetSpec.hs` (the QuickCheck properties — change the law, change the test); `DECISIONS.md` §3/§5 (the invariant is written down there — keep it honest) |
| Add a brand-new page/route (e.g. a Reports page) | New `src/Api/<Name>.hs`, same shape as `src/Api/Budget.hs` (routes type + handlers + a `render*`/`*Content` function); wire it into `RootApi`/`server` in `src/Api.hs`; add the nav link in `src/Api/Html.hs`; new `test/Api/<Name>Spec.hs` |
| Add a new database table | New numbered file in `migrations/`; a new `src/Db/<Name>.hs` module (queries + a `FromRow` instance, following `src/Db/Assignment.hs` as the smallest example); update **this file** in the same commit (see the Documentation Standard in `CLAUDE.md`) |
| Add a scheduled/recurring transaction or forecast rule (v0.2, see `DECISIONS.md` §10) | New `migrations/*_scheduled_items.sql`; a new, **pure** `src/Domain/Projection.hs` (no `IO`, reuses `rolloverCategoryMonth`/`available` — never edits them); a new `src/Db/ScheduledItem.hs`; a new `src/Api/Forecast.hs` mounted at `/forecast`. Critically: **never** make `Domain.Transaction`/`Domain.Budget`'s existing functions aware of "future" data — the real ledger stays strictly historical; a forecast is a read-only simulation layered on top, never a write to `transactions` |
| Change a validation rule (e.g. a name's max length) | `src/Domain/Validation.hs` (`nonEmptyName`) |
| Add a new kind of domain error | `src/Domain/Error.hs` (`DomainError`); whichever `Domain`/`Db` function should raise it; the `Api` handler's `case result of Left ... -> ...` that turns it into an on-page message |
| Change the SQLite pragmas, pool size, or backup behavior | `src/Db/Pool.hs` (pragmas, pool size); `src/Db/Backup.hs` (the online backup) |
| Change an env var, its default, or the port | `src/Config.hs`; then update `CLAUDE.md`'s "Config" line and `README.md` |
| Change how euros are parsed/formatted on a page | Each `src/Api/*.hs` currently has its own local `centsToEuroText`/`parseEuros` (not shared yet — see `DECISIONS.md` §8 for why that duplication is a known, deliberate-for-now tradeoff); `src/Domain/Types.hs` (`Cents`, `cents`, `centsValue`) is the one source of truth underneath all of them |
