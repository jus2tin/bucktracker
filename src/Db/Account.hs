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
import Domain.Account (Account (..))
import Domain.Error (DomainError)
import Domain.Types (AccountId (..), AccountType)
import Domain.Validation (nonEmptyName)

instance FromRow Account where
  fromRow = Account <$> field <*> field <*> field <*> field

-- | Valideert de naam en voegt, als die geldig is, een nieuwe rekening toe.
-- Het echte ID komt van SQLite (@rowid@), dus de validatie gebeurt vóór de
-- insert, zonder een nep-ID te hoeven verzinnen om 'Domain.Account.mkAccount'
-- aan te roepen (zie Domain.Validation).
insertAccount :: Connection -> Text -> AccountType -> IO (Either DomainError Account)
insertAccount conn name ty = case nonEmptyName "account" name of
  Left err -> pure (Left err)
  Right validName -> do
    execute
      conn
      "INSERT INTO accounts (name, type, archived_at) VALUES (?, ?, NULL)"
      (validName, ty)
    rowId <- lastInsertRowId conn
    pure (Right (Account (AccountId rowId) validName ty Nothing))

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
