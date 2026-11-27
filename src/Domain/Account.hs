module Domain.Account
  ( Account
  , accId
  , accName
  , accType
  , accArchivedAt
  , mkAccount
  , unsafeReconstructAccount
  , isOnBudget
  , isArchived
  , sameBudgetStatus
  ) where

import Data.Text (Text)
import Data.Time (UTCTime)
import Domain.Error (DomainError)
import Domain.Types (AccountId, AccountType (..), isOnBudgetType)
import Domain.Validation (nonEmptyName)

-- | An account. The opening balance is deliberately not stored as a
-- field, but as a plain 'Domain.Transaction.Inflow' transaction on this
-- account (see DECISIONS.md §3, "Accounts").
--
-- 'accArchivedAt': soft delete (DECISIONS.md §7) — 'Nothing' means
-- active; an archived account keeps existing for historical
-- transactions, but no longer belongs in new pickers.
data Account = Account
  { accId         :: AccountId
  , accName       :: Text
  , accType       :: AccountType
  , accArchivedAt :: Maybe UTCTime
  } deriving stock (Eq, Show)

-- | A newly created account is, by definition, not archived yet.
mkAccount :: AccountId -> Text -> AccountType -> Either DomainError Account
mkAccount aid name ty =
  (\n -> Account aid n ty Nothing) <$> nonEmptyName "account" name

-- | Rebuilds an 'Account' from data that's already valid — a row read
-- back from storage, which only exists because 'mkAccount'/'nonEmptyName'
-- already validated it once at insert time. The ordinary data
-- constructor is deliberately not exported (DECISIONS.md §8, M-10), so
-- this is the one sanctioned way for 'Db.Account' to turn a row back
-- into an 'Account' without re-running validation on every read; it is
-- not a second smart constructor, and any other caller is responsible
-- for the invariant itself.
unsafeReconstructAccount :: AccountId -> Text -> AccountType -> Maybe UTCTime -> Account
unsafeReconstructAccount = Account

isOnBudget :: Account -> Bool
isOnBudget = isOnBudgetType . accType

isArchived :: Account -> Bool
isArchived acc = case accArchivedAt acc of
  Just _  -> True
  Nothing -> False

-- | Whether two accounts have the same "budget status" (both on-budget,
-- or both tracking). A transfer between an on-budget and a tracking
-- account isn't supported in v0.1 — see DECISIONS.md §3 for why that
-- would break the core invariant. From Phase 2 onward this is also
-- actually enforced: 'Db.Transaction.insertTransfer' uses this function
-- to check the two accounts it looked up, and otherwise returns
-- 'Domain.Error.TransferRequiresMatchingBudgetStatus'.
sameBudgetStatus :: Account -> Account -> Bool
sameBudgetStatus a b = isOnBudget a == isOnBudget b
