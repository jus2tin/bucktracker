module Domain.Account
  ( Account (..)
  , mkAccount
  , isOnBudget
  , isArchived
  , sameBudgetStatus
  ) where

import Data.Text (Text)
import Data.Time (UTCTime)
import Domain.Error (DomainError)
import Domain.Types (AccountId, AccountType (..), isOnBudgetType)
import Domain.Validation (nonEmptyName)

-- | Een rekening. De beginstand wordt bewust niet als veld opgeslagen, maar
-- als een gewone 'Domain.Transaction.Inflow'-transactie op deze rekening
-- (zie DECISIONS.md §3, "Rekeningen").
--
-- 'accArchivedAt': soft-delete (DECISIONS.md §7) — 'Nothing' betekent
-- actief; een gearchiveerde rekening blijft bestaan voor historische
-- transacties, maar hoort niet meer in nieuwe keuzelijsten.
data Account = Account
  { accId         :: AccountId
  , accName       :: Text
  , accType       :: AccountType
  , accArchivedAt :: Maybe UTCTime
  } deriving stock (Eq, Show)

-- | Een nieuw aangemaakte rekening is per definitie nog niet gearchiveerd.
mkAccount :: AccountId -> Text -> AccountType -> Either DomainError Account
mkAccount aid name ty =
  (\n -> Account aid n ty Nothing) <$> nonEmptyName "account" name

isOnBudget :: Account -> Bool
isOnBudget = isOnBudgetType . accType

isArchived :: Account -> Bool
isArchived acc = case accArchivedAt acc of
  Just _  -> True
  Nothing -> False

-- | Of twee rekeningen dezelfde "budget-status" hebben (beide on-budget, of
-- beide tracking). Een transfer tussen een on-budget en een
-- tracking-rekening wordt in v0.1 niet ondersteund — zie DECISIONS.md §3
-- voor waarom dat de kerninvariant zou breken. Vanaf Fase 2 wordt dit ook
-- echt afgedwongen: 'Db.Transaction.insertTransfer' gebruikt deze functie
-- om de twee opgezochte rekeningen te controleren en geeft anders
-- 'Domain.Error.TransferRequiresMatchingBudgetStatus' terug.
sameBudgetStatus :: Account -> Account -> Bool
sameBudgetStatus a b = isOnBudget a == isOnBudget b
