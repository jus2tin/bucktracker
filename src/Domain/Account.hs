module Domain.Account
  ( Account (..)
  , mkAccount
  , isOnBudget
  , sameBudgetStatus
  ) where

import Data.Text (Text)
import qualified Data.Text as Text
import Domain.Error (DomainError (..))
import Domain.Types (AccountId, AccountType (..), isOnBudgetType)

-- | Een rekening. De beginstand wordt bewust niet als veld opgeslagen, maar
-- als een gewone 'Domain.Transaction.Inflow'-transactie op deze rekening
-- (zie DECISIONS.md §3, "Rekeningen").
data Account = Account
  { accId   :: AccountId
  , accName :: Text
  , accType :: AccountType
  } deriving stock (Eq, Show)

mkAccount :: AccountId -> Text -> AccountType -> Either DomainError Account
mkAccount aid name ty
  | Text.null (Text.strip name) = Left (EmptyName "account")
  | otherwise = Right (Account aid name ty)

isOnBudget :: Account -> Bool
isOnBudget = isOnBudgetType . accType

-- | Of twee rekeningen dezelfde "budget-status" hebben (beide on-budget, of
-- beide tracking). Een transfer tussen een on-budget en een
-- tracking-rekening wordt in v0.1 niet ondersteund — zie DECISIONS.md §3
-- voor waarom dat de kerninvariant zou breken, en waarom dit (nog) geen
-- 'DomainError' is maar een aanname op aggregaatniveau.
sameBudgetStatus :: Account -> Account -> Bool
sameBudgetStatus a b = isOnBudget a == isOnBudget b
