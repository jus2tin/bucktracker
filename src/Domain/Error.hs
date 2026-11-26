-- | Alle manieren waarop een pure domeinbewerking kan mislukken.
--
-- Platte, structurele constructoren (geen vrije foutteksten): de Api-laag
-- vertaalt dit zelf naar een HTTP-status en een boodschap in de taal van de
-- gebruiker. Zie DECISIONS.md §3 voor de redenering achter elke regel.
module Domain.Error
  ( DomainError (..)
  ) where

import Data.Text (Text)

data DomainError
  = -- | Naam van een rekening/categorie(groep) was leeg of enkel whitespace.
    -- Het veld zegt om welk soort entiteit het ging, voor een nette melding.
    EmptyName Text
  | -- | 'Domain.Types.mkYearMonth' kreeg een maandnummer buiten [1,12].
    InvalidMonth Int
  | -- | Een transfer kreeg dezelfde rekening als beide kanten.
    TransferRequiresDistinctAccounts
  | -- | Een transfer verbond een on-budget met een tracking-rekening. Dat
    -- zou invariant 1 breken (zie DECISIONS.md §3/§7): vanaf Fase 2 wordt
    -- dit afgedwongen door 'Db.Transaction.insertTransfer', die de twee
    -- rekeningen opzoekt en 'Domain.Account.sameBudgetStatus' controleert.
    TransferRequiresMatchingBudgetStatus
  deriving stock (Eq, Show)
