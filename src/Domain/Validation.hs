-- | Small, shared validation helpers for the Domain layer.
--
-- Exists so that Db.* can run a validation before inserting a row (i.e.
-- before a real database ID is known), without having to make up a fake
-- ID just to call an @mk*@ smart constructor.
module Domain.Validation
  ( nonEmptyName
  , validatePayee
  ) where

import Data.Char (isControl)
import Data.Text (Text)
import qualified Data.Text as Text
import Domain.Error (DomainError (EmptyName, InvalidCharacters, NameTooLong))

maxNameLength :: Int
maxNameLength = 80

maxPayeeLength :: Int
maxPayeeLength = 160

-- | Rejects an empty or whitespace-only name, a name containing a
-- control character, or one longer than 'maxNameLength' (AUDIT-08) —
-- otherwise returns the trimmed name. @kind@ names the kind of entity
-- (e.g. "account") for a decent error message.
nonEmptyName :: Text -> Text -> Either DomainError Text
nonEmptyName kind name
  | Text.null stripped = Left (EmptyName kind)
  | Text.any isControl stripped = Left (InvalidCharacters kind)
  | Text.length stripped > maxNameLength = Left (NameTooLong kind maxNameLength)
  | otherwise = Right stripped
  where
    stripped = Text.strip name

-- | A transaction's free-form payee (DECISIONS.md §3, "Payee"):
-- trimmed, capped at 'maxPayeeLength', no control characters — but
-- (unlike 'nonEmptyName') an empty payee is allowed, since nothing else
-- in the domain requires one.
validatePayee :: Text -> Either DomainError Text
validatePayee payee
  | Text.any isControl stripped = Left (InvalidCharacters "payee")
  | Text.length stripped > maxPayeeLength = Left (NameTooLong "payee" maxPayeeLength)
  | otherwise = Right stripped
  where
    stripped = Text.strip payee
