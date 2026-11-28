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

## Static assets

Pico CSS, HTMX, and Alpine.js (the `@alpinejs/csp` build) are vendored,
pinned, minified files checked into `static/` — never fetched from a
CDN, never run through a bundler. They're installed via Cabal
`data-files` (`package.yaml`, the exact mechanism `migrations/*.sql`
already used — see `DECISIONS.md` §7/§12), located at runtime via the
generated `Paths_bucktracker.getDataDir`, and stored once at startup as
`appStaticDir` on `AppEnv` (`src/Api/Monad.hs`). `Api.hs` mounts
`"static" :> Raw`, served via `wai-app-static`'s `serveDirectoryWith`
with `ssMaxAge = NoMaxAge` — deliberately not `servant-server`'s own
`serveDirectoryWebApp`, whose default one-year `Cache-Control: max-age`
is right for content-hashed CDN assets but wrong here: these files have
no hash in their names and change on every Track A step, and a
year-long browser cache silently serving a stale `app.js` past a
rebuild is exactly the kind of bug a live-browser check (CLAUDE.md
"Run the app") exists to catch, not reproduce. So `GET /static/pico.min.css`, `/static/app.css`, `/static/htmx.min.js`,
`/static/alpine-csp.min.js`, and our own `/static/app.js` all just work,
including in tests (`Api.Setup` resolves the same `appStaticDir` the
real app does). `Api.Html.page` links all five from `<head>` — zero
inline `<style>` elements (all app overrides, `.htmx-indicator`, and
`[x-cloak]` live in `/static/app.css`, paired with `<meta
name="htmx-config" content='{"includeIndicatorStyles":false}'>` so HTMX
never injects an inline stylesheet at boot either), and `htmx.min.js`,
`app.js`, and `alpine-csp.min.js` deferred in that exact order so
`Alpine.data(...)` components register before Alpine initializes. Server
values passed into Alpine components always travel via `data-*`
attributes (`data-initial-value`, `data-cleared-cents`,
`data-archived-extra`), never string-interpolated into `x-*` attributes,
keeping every page clean under strict `script-src 'self'; style-src
'self'` Content-Security-Policy. No CDN, no network dependency:
Bucktracker works fully offline.

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
   `Header "HX-Request" Text :> "transactions" :> "spending" :>
   ReqBody '[FormUrlEncoded] NewSpendingForm :> Post '[HTML] (Html ())`.
   Servant matches the URL and method, decodes the raw form fields (all
   plain `Text`) into a `NewSpendingForm` record via `FromForm` —
   matched by the HTML `name="..."` attributes — and hands the handler
   the `HX-Request` header as a `Maybe Text` (HTMX always sends
   `HX-Request: true`; a plain browser form POST never sends it at
   all).

3. **The handler does HTTP-shaped validation.**
   `createSpendingHandler` (via `withValidSpending`) turns the form's
   `Text` fields into real types: an `AccountId`, `CategoryId`s, a `Day`
   (bounded to years `1900..2200` via `parseIsoDate`, matching
   `Domain.Types.mkYearMonth`), a validated payee (`validatePayee`:
   trimmed, `<= 160` chars, no control characters), and `Cents` amounts
   — using small total parsers (`parseAccountId`,
   `Api.Money.parseNonZeroSignedEuros`, `parseIsoDate`; never
   `Prelude.read`, which can crash on bad input). It rejects unequal
   `lineCategoryId`/`lineAmount` field counts rather than silently
   truncating via `zip`, and checks the account and categories actually
   exist and are not archived. Anything wrong here short-circuits
   straight to an error message — the database is never touched.

4. **The Db layer does the real write.** The handler calls
   `Db.insertSpending` (`src/Db/Transaction.hs`), which runs inside one
   SQLite transaction: it builds a `Domain.Transaction.TransactionLine`
   and assembles a real `Transaction` via
   `Domain.Transaction.mkSpendingTransaction`, checks the account is
   on-budget (rejecting with the `DomainError`
   `CategorizedTransactionRequiresOnBudgetAccount` if not — see
   "Illegal states, unrepresentable" below), and only then runs the
   `INSERT`s into `transactions` and `transaction_lines`.

5. **Success re-renders, fragment or full page.** `renderFragment`
   re-reads the current month's accounts/categories/transactions
   straight back out of `Db.*` and builds the updated
   `#transactions-content` `Html ()` value with ordinary Lucid
   combinators (`table_`, `tr_`, `td_`, …) — there's no diffing or
   templating language, it's just Haskell building a tree of HTML. It
   then hands that, and the `HX-Request` header from step 2, to
   `Api.Html.pageOrFragment`: an HTMX request gets just that `Html ()`
   value back; a plain browser request (HTMX didn't load, is blocked,
   or JS is off) gets it wrapped in a full `Api.Html.page` instead —
   the progressive-enhancement fallback, since every `<form>` also
   carries a real `method="post" action="..."` pair, so a plain
   submission is a genuine page navigation, not a dead click. This one
   function is also what fixed a real bug: earlier, `Api.Transactions`
   and `Api.Budget` wrapped *every* response in `page` unconditionally,
   so HTMX kept swapping a full document — `<head>`, `<nav>`, scripts
   and all — into `#transactions-content`/`#budget-content`, nesting a
   new copy of the page inside itself on every single click.

6. **Servant serializes it, HTMX swaps it in.** `servant-lucid`'s
   `MimeRender` instance turns that `Html ()` into the HTTP response
   body. HTMX receives the 200 and replaces `#transactions-content` —
   the new expense's row appears, with no full page reload.

Every other page (`Api.Accounts`, `Api.Categories`, `Api.Budget`) is
the exact same shape: parse the form → ask `Domain`/`Db` to do the real
work → re-render through `pageOrFragment` on success *or* on a
validation error (so the error banner and the unchanged table render
together, not a separate error page).

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
  `mkYearMonth`, …) that validates as it goes (`mkYearMonth` bounds
  months to `1..12` and years to `1900..2200` via `InvalidMonth` /
  `InvalidYear`; `Domain.Validation.nonEmptyName` trims whitespace,
  caps names at `80` characters, and rejects control characters;
  `mkTransferPair` enforces strictly positive amounts via
  `TransferAmountMustBePositive`), or — for the `Db` layer reading
  already-valid data back out of storage — a clearly-named
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

**Moving money back out of a category.** Groceries' carried-in €50
isn't stuck there — assigning it a **negative** amount (`-€50.00`, via
`Api.Money.parseSignedEuros`) sends that €50 back to Ready to Assign:
`available = €50 (carried in) + (-€50) (assigned) + €0 = €0`, and
`readyToAssign`'s `negateCents (assignedTotal month assignments)` term
flips the sign, adding the €50 back. The `/budget` page's "Assigned" cell is editable inline (click it,
type, Enter or Escape) via an Alpine component (`static/app.js`'s
`inlineAssign`, registered through `Alpine.data` with
`x-data="inlineAssign()"` and reading its server-rendered starting text
from `data-initial-value` — the vendored build is CSP-restricted, so
there's no inline `x-data="{ ... }"` object literal, no dynamic string
interpolation inside `x-*`, and every `x-on` handler calls a named
method with `()`, e.g. `x-on:click="startEdit()"`, never a bare
reference); without JS, it's still an ordinary `<form>` whose single
text input submits on Enter.

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

On the Transactions page, the spending form is a genuine arbitrary-
length (1..N) split editor, not a fixed number of slots: every split
line's category/amount inputs share the same `name` attributes
(`lineCategoryId`/`lineAmount`) regardless of how many lines exist, and
`Api.Transactions.NewSpendingForm`'s hand-written `FromForm` instance
collects all of them via `Web.FormUrlEncoded.lookupAll` rather than
`Generic`-deriving fixed field names. The Alpine `splitEditor` component (`static/app.js`) adds/removes rows
by cloning/removing a plain `.split-line` DOM node — stripping any
`option[data-archived-extra]` and prefilled `value` attribute from cloned
rows so a newly added split line never inherits an archived category —
and shows a live, client-side-only "Unallocated: €X" preview as you type
(a receipt total minus the lines' sum, in integer cents); Haskell never
trusts that figure and still derives `transactionAmount` strictly from
whatever lines actually arrive (invariant 3).

A line's amount is *signed*: typing a negative amount
(`Api.Money.parseNonZeroSignedEuros`) records a refund/credit against
that category rather than an expense — the existing `negateCents`
convention (a typed `40.00` is stored as `-€40`) already turns a typed
`-15.00` into a stored `+€15` for free, so refunds needed no change to
that convention, only to the parser accepting a sign at all. An
inflow's amount is signed the same way (a negative inflow is an
opening-balance correction); a transfer's amount stays strictly
positive, since the direction is already chosen by which account is
"from" and which is "to".

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
to whatever you type in. The statement-balance field is signed
(`Api.Money.parseSignedEuros`, zero included) so an overdrawn checking
account or a negative-balance liability can reconcile too; an Alpine
`reconcileCalc` component (`static/app.js`) reads the account's current
`clearedBalance` off a `data-cleared-cents` attribute the server
renders and shows a live "Cleared − Statement = Difference" preview as
you type, before you even click "Reconcile" — again purely a preview,
never the actual comparison. On submission, `Db.Transaction.reconcileAccountIfMatches` runs inside a
single SQLite transaction: it loads the account's transactions, compares
`clearedBalance` against `statementBalance`, and on a match locks every
`Cleared` transaction on that account in as `Reconciled`; on a mismatch,
nothing is written at all and `Left actualClearedBalance` comes back so
you can go find the missing, duplicate, or still-uncleared transaction
yourself.

### Entry drawers and keyboard shortcuts

The three entry forms on the Transactions page (Inflow, Expense,
Transfer) are each wrapped in a plain `<details>`/`<summary>` rather
than a `<dialog>` modal — native, no JS required for open/close, and no
focus-trap behavior to get wrong. A document-level `keydown` listener
in `static/app.js` (not an Alpine component — it has no per-element
state, just global key handling) opens the matching drawer on `n`
(Expense), `i` (Inflow), or `t` (Transfer) and focuses its first field,
ignoring the shortcut entirely while focus is already in an input/
textarea/select or a modifier key is held; `Escape` closes whichever
drawer is open, everywhere on the page.

### Editing and deleting a transaction

A transaction's row on `/transactions` has an "Edit" `<details>`
drawer (pre-filled, reusing the same create-form renderers and the
split editor) and a "Delete" button with `hx-confirm`; neither renders
once the transaction is locked (`isLockedTransaction`: either the row
itself is `Reconciled`, or it is a `TransferLeg` whose sibling leg on
the counterpart account is already `Reconciled`).
`Db.Transaction.deleteTransaction` and the `update*` family
(`updateInflow`/`updateSpending`/`updateTransfer`) all go through a
shared `withReplaceable` inside one SQLite transaction: look up the
transaction (plus `transferSiblingsOf` when it's a transfer), reject
with `CannotModifyReconciledTransaction` if the row or any sibling
transfer leg is `Reconciled`, verify the row's existing categorization
matches the requested edit route (`TransactionKindMismatch` blocks
cross-kind overwrites), delete its old row(s) (both legs plus the shared
`transfers` row, for a transfer), and — for an edit — insert the new
ones through the exact same raw row-insert helpers a fresh create uses.
`updateInflow` and `updateSpending` preserve `txImportHash` whenever the
transaction stays on the same account (`preservedImportHash`, dropping
it if moved to another account), and `updateTransfer` preserves each
leg's independent `Uncleared`/`Cleared` status per account rather than
clobbering one leg with the other's status. The edited transaction gets
a *new* `TransactionId` — nothing in Bucktracker outside of one page
render depends on an id staying stable across an edit (and SQLite's own
rowid allocator can reuse a deleted row's id anyway, so "the old id is
gone" isn't even a safe assumption to test for).

### Month navigation, local dates, and the account filter

Both `/budget` and `/transactions` show whichever month `?month=YYYY-MM`
names, defaulting to today's *local* calendar month — `Api.Monad
.localToday` (via `Data.Time.LocalTime.getZonedTime`), not
`getCurrentTime`/`utctDay`, since a UTC "today" can roll over several
hours early or late for anyone not in UTC themselves (Architect review
S-4). `Api.Monad.resolveViewedMonth` is the one shared parser: an
absent or unparseable `?month=` just falls back, exactly as if it had
been omitted, through `Domain.Types.parseYearMonth`/`yearMonthToText`
(the canonical `"YYYY-MM"` text form). Both pages' Prev/Next links are
a plain `<ul>`, not a `<nav>` — the latter is already what `Api.Html
.page` uses for the site-wide header, and the fragment-vs-full-page
tests tell them apart by that element's absence.

Budget's inline-assign form carries the viewed month in a hidden
`assignMonth` field, so assigning while browsing a past or future month
assigns into *that* month, not silently back into the current one.
Transactions' six forms (three create, three edit) don't carry the
viewed month/account filter the same way — a deliberate v0.1
simplification: every mutating action there (create, edit, delete,
clear) re-renders the *default* view (today's month, no filter)
afterward, rather than threading two more hidden fields through every
form. Browsing March, creating a transaction, and landing back on the
current month is a minor rough edge, not a correctness issue.

`/transactions?account=<id>` filters the register to one account (the
Accounts page links each account's name there); the filter rides along
on the Prev/Next links (`&account=<id>`) so navigating months while
filtered doesn't silently drop it. The register also gained the
missing **Account** column — every row now shows which account it
belongs to, filtered or not.

### Archiving, unarchiving, and entity guards

Accounts, category groups, and categories are never hard-deleted —
historical transactions and past monthly rollovers still reference
them, so "deleting" is soft-delete via a nullable `archived_at`
timestamp (`DECISIONS.md` §7, §11).

Archiving is **two-way** and **guarded** on both the UI and server
sides:

- **Confirmation & undo:** Every active account, category group, and
  category renders an `Archive` button gated by `hx-confirm` so a stray
  click doesn't immediately hide an entity; once archived, the same
  column switches to an `Unarchive` button (`Db.Account.unarchiveAccount`,
  `Db.Category.unarchiveCategoryGroup`, `Db.Category.unarchiveCategory`).
  Both `archive*` (`WHERE id = ? AND archived_at IS NULL`) and
  `unarchive*` (`WHERE id = ? AND archived_at IS NOT NULL`) are
  idempotent.
- **Preconditions before archiving:**
  - An **account** cannot be archived while `Domain.Budget.accountBalance`
    is non-zero **or** while any transaction on it is not yet
    `Reconciled` (`Api.Accounts.archiveAccountHandler`) — hiding an
    account that still holds money or unreconciled rows would either
    leave funds invisible in entry pickers or permanently hide the
    `Reconcile` form (`reconcileCell`) before those rows were reconciled.
  - A **category** cannot be archived while its folded
    `Domain.Budget.available` balance is non-zero in the current month
    **or any future month** (`Api.Categories.archiveCategoryHandler` via
    `hasNonZeroBalanceFromNowOn`, using `Domain.Budget.monthsThrough` +
    `rolloverMonths` across all months `>= today`, preventing future
    assignments from being stranded). On `/budget`, archived categories
    with zero `Carried In`, `Assigned`, `Activity`, and `Available` are
    hidden from the table while remaining inside `rolloverMonths` so
    Invariant 1 holds across the entire ledger history.
  - A **category group** cannot be archived while any child category in
    it is still active (`Api.Categories.archiveCategoryGroupHandler`).
- **Server-side guards against writing to archived entities:**
  - Creating a category inside an archived group is rejected by
    `Db.Category.insertCategory` (`Left ArchivedCategoryGroup`).
  - Assigning money to an archived category is rejected by
    `Api.Budget.assignHandler`.
  - Creating a new inflow, spending transaction, or transfer against an
    archived account (or an archived category on any split line) is
    rejected server-side in `Api.Transactions` (`createInflowHandler`,
    `createSpendingHandler`, `createTransferHandler`), not merely hidden
    in `<select>` menus. The spending create form also filters its
    account picker to **active on-budget accounts only**
    (`accountChoices True Nothing`), never offering `Tracking` accounts
    that would fail `CategorizedTransactionRequiresOnBudgetAccount`.
  - **Edit-form exception (`accountChoices` / `categoryChoices` &
    `movesOntoArchived*`):** Editing an *existing* historical
    transaction on a since-archived account or category appends that one
    entity (labelled `"(archived)"`) back into the edit form's `<select>`
    so opening and saving an edit never silently reassigns the
    transaction to a different active option — while `movesOntoArchivedAccount`,
    `movesOntoArchivedCategory`, and `movesOntoArchivedTransferAccount`
    still reject moving a transaction onto a *different*, newly chosen
    archived account or category.
- **First-run onboarding:** When no accounts or category groups/categories
  exist yet, `/accounts` and `/categories` render plain-English
  `onboardingBanner` prompts explaining what to create first instead of
  bare empty tables.

## Where do I change X?

| I want to... | Touch these files |
|---|---|
| Add a field to `Account` (or `Category`/`CategoryGroup`) | New numbered file in `migrations/` (the column); `src/Domain/Account.hs` (the field, `mkAccount`, `unsafeReconstructAccount`); `src/Db/Field.hs` if it's a new scalar type; `src/Db/Account.hs` (the `FromRow` instance and every `SELECT`/`INSERT`); `src/Api/Accounts.hs` (the form field and the HTML table column) |
| Change what happens at month rollover (e.g. partial carry, a cap) | `src/Domain/Budget.hs` (`rolloverCategoryMonth`, `rolloverMonths`); `test/Domain/BudgetSpec.hs` (the QuickCheck properties — change the law, change the test); `DECISIONS.md` §3/§5 (the invariant is written down there — keep it honest) |
| Add a brand-new page/route (e.g. a Reports page) | New `src/Api/<Name>.hs`, same shape as `src/Api/Budget.hs` (routes type + handlers + a `render*`/`*Content` function); wire it into `RootApi`/`server` in `src/Api.hs`; add the nav link in `src/Api/Html.hs`; new `test/Api/<Name>Spec.hs` |
| Add a new database table | New numbered file in `migrations/`; a new `src/Db/<Name>.hs` module (queries + a `FromRow` instance, following `src/Db/Assignment.hs` as the smallest example); flag for the Architect to update **this file** after commit (see `GEMINI.md`) |
| Add or update a vendored static asset (CSS/JS) | Drop the file in `static/`; it's already covered by the `static/*.css`/`static/*.js` globs in `package.yaml`'s `data-files` — no other wiring needed, it's served automatically at `/static/<filename>` |
| Add a scheduled/recurring transaction or forecast rule (v0.2, see `DECISIONS.md` §10) | New `migrations/*_scheduled_items.sql`; a new, **pure** `src/Domain/Projection.hs` (no `IO`, reuses `rolloverCategoryMonth`/`available` — never edits them); a new `src/Db/ScheduledItem.hs`; a new `src/Api/Forecast.hs` mounted at `/forecast`. Critically: **never** make `Domain.Transaction`/`Domain.Budget`'s existing functions aware of "future" data — the real ledger stays strictly historical; a forecast is a read-only simulation layered on top, never a write to `transactions` |
| Add recurring obligations, subscriptions, or sinking-fund auto-funding (`/recurring`, Track E — see `DECISIONS.md` §13 & `docs/phases/track-e-recurring-spec.md`) | Planned after Tracks B–D: `recurring_rules` targets natural budget categories (`Entertainment`, `Sport`, `Housing`) with an orthogonal `is_fixed_obligation` flag, `1/3` quarterly and `1/12` annual integer-cent sinking-fund accruals, `Funded`/`Paid`/`Due` status on `/recurring`, and an idempotent one-click *"Fund Recurring"* action writing standard `assignments` rows |
| Change a validation rule (e.g. a name's or payee's max length) | `src/Domain/Validation.hs` (`nonEmptyName` — trimmed, `<= 80` chars, no control chars; `validatePayee` — trimmed, `<= 160` chars, no control chars) |
| Add a new kind of domain error | `src/Domain/Error.hs` (`DomainError`); whichever `Domain`/`Db` function should raise it; the `Api` handler's `case result of Left ... -> ...` that turns it into an on-page message |
| Change the SQLite pragmas, pool size, or backup behavior | `src/Db/Pool.hs` (pragmas, pool size); `src/Db/Backup.hs` (the online backup) |
| Change an env var, its default, or the port | `src/Config.hs`; then update `CLAUDE.md`'s "Config" line and `README.md` |
| Change how euros are parsed/formatted on a page | `src/Api/Money.hs` — `parseSignedEuros`/`parseNonZeroSignedEuros`/`parsePositiveEuros`/`centsToEuroText`, shared by every `Api.*` module (DECISIONS.md §12, Architect review S-2). All euro fields now go through one of these three; which one encodes that field's legal range (e.g. a reconcile statement balance or a budget assignment can be negative or zero via `parseSignedEuros`, a split line/inflow can be negative but never exactly zero via `parseNonZeroSignedEuros`, a transfer must be strictly positive via `parsePositiveEuros`) |
| Add or remove a split line, or change how many a transaction can have | `src/Api/Transactions.hs` — `NewSpendingForm`'s `FromForm` instance (`lookupAll "lineCategoryId"`/`"lineAmount"`) collects however many `lineCategoryId`/`lineAmount` pairs the form submits (`withValidSpending` rejects unequal counts); `parseSplitLines` parses them; nothing caps the count server-side. Client-side add/remove rows: `static/app.js`'s `splitEditor` Alpine component |
| Change what deleting/editing a transaction allows or blocks | `src/Db/Transaction.hs` — `withReplaceable` (the shared `withTransaction` guard + `transferSiblingsOf` lock check), `deleteTransaction`, `updateInflow`/`updateSpending`/`updateTransfer` (`preservedImportHash`, `expectInflow`/`expectCategorized`/`expectTransferLeg`); `src/Api/Transactions.hs` (`isLockedTransaction`, `movesOntoArchived*`); `src/Domain/Error.hs` (`CannotModifyReconciledTransaction`, `TransactionKindMismatch`); `test/Db/TransactionSpec.hs` |
| Change month navigation, the local-date default, or add it to a new page | `src/Api/Monad.hs` (`localToday`, `resolveViewedMonth` — shared by every page with a `?month=`); `src/Domain/Types.hs` (`mkYearMonth` `[1900, 2200]` year bound, `yearMonthToText`/`parseYearMonth`); `src/Api/Transactions.hs` (`parseIsoDate`); the page's own `monthNav` function (deliberately a `<ul>`, never a `<nav>` — see "Month navigation, local dates, and the account filter") |
| Change the account filter on `/transactions`, or add one to another page | `src/Api/Transactions.hs` — `parseAccountFilterText`, the `QueryParam "account" Text`, `accountFilterBanner`; linked from `src/Api/Accounts.hs`'s `accountRow` |
| Change what archiving/unarchiving an account, category, or group allows or blocks | `src/Db/Account.hs` (`archiveAccount`, `unarchiveAccount`); `src/Db/Category.hs` (`archiveCategoryGroup`, `unarchiveCategoryGroup`, `archiveCategory`, `unarchiveCategory`, `insertCategory`'s `ArchivedCategoryGroup` check); `src/Api/Accounts.hs` (`archiveAccountHandler`, `unarchiveAccountHandler`, `archiveToggleButton`, `reconcileCell`); `src/Api/Categories.hs` (`archiveCategoryGroupHandler`, `archiveCategoryHandler`, `hasNonZeroBalanceFromNowOn`); `src/Api/Budget.hs` (`assignHandler`, `isVisible`); `src/Api/Transactions.hs` (`accountChoices`, `categoryChoices`, `create*Handler` & `movesOntoArchived*` guards) |
