module Db.Account
  ( insertAccount
  , getAccount
  , listAccounts
  , archiveAccount
  ) where

import Data.Maybe (listToMaybe)
import Data.Text (Text)
import Data.Time (getCurrentTime)
import Database.SQLite.Simple
  ( Connection
  , FromRow (..)
  , Only (Only)
  , execute
  , field
  , lastInsertRowId
  , query
  , query_
  )
import Db.Field ()
import Domain.Account (Account, unsafeReconstructAccount)
import Domain.Error (DomainError)
import Domain.Types (AccountId (..), AccountType)
import Domain.Validation (nonEmptyName)

instance FromRow Account where
  fromRow = unsafeReconstructAccount <$> field <*> field <*> field <*> field

-- | Validates the name and, if it's valid, inserts a new account. The
-- real ID comes from SQLite (@rowid@), so validation happens before the
-- insert, without having to make up a fake ID to call
-- 'Domain.Account.mkAccount' (see Domain.Validation).
insertAccount :: Connection -> Text -> AccountType -> IO (Either DomainError Account)
insertAccount conn name ty = case nonEmptyName "account" name of
  Left err -> pure (Left err)
  Right validName -> do
    execute
      conn
      "INSERT INTO accounts (name, type, archived_at) VALUES (?, ?, NULL)"
      (validName, ty)
    rowId <- lastInsertRowId conn
    pure (Right (unsafeReconstructAccount (AccountId rowId) validName ty Nothing))

getAccount :: Connection -> AccountId -> IO (Maybe Account)
getAccount conn aid = do
  rows <- query conn "SELECT id, name, type, archived_at FROM accounts WHERE id = ?" (Only aid)
  pure (listToMaybe rows)

listAccounts :: Connection -> IO [Account]
listAccounts conn = query_ conn "SELECT id, name, type, archived_at FROM accounts ORDER BY id"

archiveAccount :: Connection -> AccountId -> IO ()
archiveAccount conn aid = do
  now <- getCurrentTime
  execute conn "UPDATE accounts SET archived_at = ? WHERE id = ?" (now, aid)
