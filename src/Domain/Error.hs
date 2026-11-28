-- | Every way a pure domain operation can fail.
--
-- Plain, structural constructors (no free-form error text): the Api layer
-- translates this itself into an HTTP status and a message in the user's
-- language. See DECISIONS.md §3 for the reasoning behind each case.
module Domain.Error
  ( DomainError (..)
  ) where

import Data.Text (Text)

data DomainError
  = -- | An account/category(group) name was empty or whitespace-only.
    -- The field names the kind of entity, for a decent error message.
    EmptyName Text
  | -- | 'Domain.Types.mkYearMonth' got a month number outside [1,12].
    InvalidMonth Int
  | -- | 'Domain.Types.mkYearMonth' got a year outside [1900,2200]
    -- (AUDIT-01): unbounded years let 'Domain.Budget.monthsThrough' fold
    -- over billions of months (OOM) or, at @maxBound :: Int@, loop
    -- forever on 'Int' wraparound — this closes both off at the smart
    -- constructor, the one place every @YearMonth@ is built.
    InvalidYear Int
  | -- | A transfer got the same account on both sides.
    TransferRequiresDistinctAccounts
  | -- | A transfer connected an on-budget account with a tracking
    -- account. That would break invariant 1 (see DECISIONS.md §3/§7):
    -- from Phase 2 onward this is enforced by
    -- 'Db.Transaction.insertTransfer', which looks up the two accounts
    -- and checks 'Domain.Account.sameBudgetStatus'.
    TransferRequiresMatchingBudgetStatus
  | -- | A 'Domain.Transaction.Categorized' transaction was attempted on
    -- a tracking account. Would also break invariant 1 (a tracking
    -- account's balance is excluded from 'Domain.Budget.onBudgetBalanceTotal',
    -- but its categorized activity would still count toward
    -- 'Domain.Budget.categoryActivity'/'available'). Enforced by
    -- 'Db.Transaction.insertSpending'.
    CategorizedTransactionRequiresOnBudgetAccount
  | -- | A delete or edit targeted a transaction whose status is
    -- 'Domain.Types.Reconciled'. Reconciling is meant to be a lock: once
    -- an account's balance has been confirmed against a bank statement,
    -- changing what it was reconciled from would silently invalidate
    -- that confirmation. Enforced by 'Db.Transaction.deleteTransaction'
    -- and the @update*@ family.
    CannotModifyReconciledTransaction
  | -- | 'Db.Category.insertCategory' targeted a 'Domain.Category.CategoryGroup'
    -- that's already archived (Track A Step 6, DECISIONS.md §11): an
    -- archived group is meant to be a dead end for new children, not
    -- just a label — otherwise a group archived to get it out of the
    -- "add category" picker could still silently grow new categories
    -- through this route.
    ArchivedCategoryGroup
  | -- | An @update*@ targeted a transaction whose stored
    -- 'Domain.Transaction.Categorization' doesn't match the kind of
    -- edit being attempted (AUDIT-03.2): e.g. posting to
    -- @edit-inflow@ for an id that's actually a split or a transfer
    -- leg. Without this check, 'Db.Transaction.withReplaceable' would
    -- delete whatever that row actually was (both legs, for a
    -- transfer!) and silently replace it with the wrong kind.
    TransactionKindMismatch
  | -- | A name (account, category, category group) contained a
    -- control character after trimming (AUDIT-08).
    InvalidCharacters Text
  | -- | A name or payee exceeded its maximum length (AUDIT-08). The
    -- 'Int' is that maximum.
    NameTooLong Text Int
  | -- | A transfer's amount was zero or negative. 'Api.Money.parsePositiveEuros'
    -- already rejects this at the edge, but 'Domain.Transaction.mkTransferPair'
    -- and 'Db.Transaction.insertTransfer'/'updateTransfer' enforce it
    -- again as defense in depth (AUDIT-08) — the sign of a transfer is
    -- decided entirely by which account is "from" and which is "to",
    -- never by the amount itself.
    TransferAmountMustBePositive
  deriving stock (Eq, Show)
