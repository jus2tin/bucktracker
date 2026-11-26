module Db.Category
  ( insertCategoryGroup
  , listCategoryGroups
  , archiveCategoryGroup
  , insertCategory
  , listCategories
  , listCategoriesInGroup
  , archiveCategory
  ) where

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
import Domain.Category (Category (..), CategoryGroup (..))
import Domain.Error (DomainError)
import Domain.Types (CategoryGroupId (..), CategoryId (..))
import Domain.Validation (nonEmptyName)

instance FromRow CategoryGroup where
  fromRow = CategoryGroup <$> field <*> field <*> field

instance FromRow Category where
  fromRow = Category <$> field <*> field <*> field <*> field

insertCategoryGroup :: Connection -> Text -> IO (Either DomainError CategoryGroup)
insertCategoryGroup conn name = case nonEmptyName "category group" name of
  Left err -> pure (Left err)
  Right validName -> do
    execute conn "INSERT INTO category_groups (name, archived_at) VALUES (?, NULL)" (Only validName)
    rowId <- lastInsertRowId conn
    pure (Right (CategoryGroup (CategoryGroupId rowId) validName Nothing))

listCategoryGroups :: Connection -> IO [CategoryGroup]
listCategoryGroups conn =
  query_ conn "SELECT id, name, archived_at FROM category_groups ORDER BY id"

archiveCategoryGroup :: Connection -> CategoryGroupId -> IO ()
archiveCategoryGroup conn gid = do
  now <- getCurrentTime
  execute conn "UPDATE category_groups SET archived_at = ? WHERE id = ?" (now, gid)

insertCategory :: Connection -> CategoryGroupId -> Text -> IO (Either DomainError Category)
insertCategory conn gid name = case nonEmptyName "category" name of
  Left err -> pure (Left err)
  Right validName -> do
    execute
      conn
      "INSERT INTO categories (group_id, name, archived_at) VALUES (?, ?, NULL)"
      (gid, validName)
    rowId <- lastInsertRowId conn
    pure (Right (Category (CategoryId rowId) gid validName Nothing))

listCategories :: Connection -> IO [Category]
listCategories conn =
  query_ conn "SELECT id, group_id, name, archived_at FROM categories ORDER BY id"

listCategoriesInGroup :: Connection -> CategoryGroupId -> IO [Category]
listCategoriesInGroup conn gid =
  query
    conn
    "SELECT id, group_id, name, archived_at FROM categories WHERE group_id = ? ORDER BY id"
    (Only gid)

archiveCategory :: Connection -> CategoryId -> IO ()
archiveCategory conn cid = do
  now <- getCurrentTime
  execute conn "UPDATE categories SET archived_at = ? WHERE id = ?" (now, cid)
