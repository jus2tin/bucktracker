-- | Kleine, gedeelde validatie-helpers voor de Domain-laag.
--
-- Bestaat zodat Db.* een validatie kan uitvoeren vóórdat het een rij
-- invoegt (en dus vóórdat er een echte database-ID bekend is), zonder een
-- nep-ID te moeten verzinnen om een @mk*@-smart constructor aan te roepen.
module Domain.Validation
  ( nonEmptyName
  ) where

import Data.Text (Text)
import qualified Data.Text as Text
import Domain.Error (DomainError (EmptyName))

-- | Wijst een lege of enkel-whitespace naam af. @kind@ benoemt het soort
-- entiteit (bv. "account") voor een nette foutmelding.
nonEmptyName :: Text -> Text -> Either DomainError Text
nonEmptyName kind name
  | Text.null (Text.strip name) = Left (EmptyName kind)
  | otherwise = Right name
