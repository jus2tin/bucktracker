-- | Small, shared validation helpers for the Domain layer.
--
-- Exists so that Db.* can run a validation before inserting a row (i.e.
-- before a real database ID is known), without having to make up a fake
-- ID just to call an @mk*@ smart constructor.
module Domain.Validation
  ( nonEmptyName
  ) where

import Data.Text (Text)
import qualified Data.Text as Text
import Domain.Error (DomainError (EmptyName))

-- | Rejects an empty or whitespace-only name. @kind@ names the kind of
-- entity (e.g. "account") for a decent error message.
nonEmptyName :: Text -> Text -> Either DomainError Text
nonEmptyName kind name
  | Text.null (Text.strip name) = Left (EmptyName kind)
  | otherwise = Right name
