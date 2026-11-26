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
  deriving stock (Eq, Show)
