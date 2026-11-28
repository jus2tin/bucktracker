module Db.Category
  ( insertCategoryGroup
  , listCategoryGroups
  , getCategoryGroup
  , archiveCategoryGroup
  , unarchiveCategoryGroup
  , insertCategory
  , listCategories
  , listCategoriesInGroup
  , archiveCategory
  , unarchiveCategory
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
import Domain.Category
  ( Category
  , CategoryGroup
  , isArchivedGroup
  , unsafeReconstructCategory
  , unsafeReconstructCategoryGroup
  )
import Domain.Error (DomainError (..))
import Domain.Types (CategoryGroupId (..), CategoryId (..))
import Domain.Validation (nonEmptyName)

instance FromRow CategoryGroup where
  fromRow = unsafeReconstructCategoryGroup <$> field <*> field <*> field

instance FromRow Category where
  fromRow = unsafeReconstructCategory <$> field <*> field <*> field <*> field

insertCategoryGroup :: Connection -> Text -> IO (Either DomainError CategoryGroup)
insertCategoryGroup conn name = case nonEmptyName "category group" name of
  Left err -> pure (Left err)
  Right validName -> do
    execute conn "INSERT INTO category_groups (name, archived_at) VALUES (?, NULL)" (Only validName)
    rowId <- lastInsertRowId conn
    pure (Right (unsafeReconstructCategoryGroup (CategoryGroupId rowId) validName Nothing))

listCategoryGroups :: Connection -> IO [CategoryGroup]
listCategoryGroups conn =
  query_ conn "SELECT id, name, archived_at FROM category_groups ORDER BY id"

getCategoryGroup :: Connection -> CategoryGroupId -> IO (Maybe CategoryGroup)
getCategoryGroup conn gid = do
  rows <- query conn "SELECT id, name, archived_at FROM category_groups WHERE id = ?" (Only gid)
  pure (listToMaybe rows)

-- | Idempotent (@AND archived_at IS NULL@) — see 'Db.Account.archiveAccount'.
archiveCategoryGroup :: Connection -> CategoryGroupId -> IO ()
archiveCategoryGroup conn gid = do
  now <- getCurrentTime
  execute conn "UPDATE category_groups SET archived_at = ? WHERE id = ? AND archived_at IS NULL" (now, gid)

-- | The undo for 'archiveCategoryGroup' — see 'Db.Account.unarchiveAccount'.
unarchiveCategoryGroup :: Connection -> CategoryGroupId -> IO ()
unarchiveCategoryGroup conn gid =
  execute conn "UPDATE category_groups SET archived_at = NULL WHERE id = ? AND archived_at IS NOT NULL" (Only gid)

-- | Rejects a category aimed at an already-archived group
-- ('Domain.Error.ArchivedCategoryGroup') before it's ever persisted — an
-- archived group is meant to be a dead end for new children (Track A
-- Step 6). A @gid@ that doesn't exist at all falls through unchanged
-- (the Api layer already checks existence against its own fetched
-- group list before ever calling this); this only adds the *archived*
-- check on top.
insertCategory :: Connection -> CategoryGroupId -> Text -> IO (Either DomainError Category)
insertCategory conn gid name = case nonEmptyName "category" name of
  Left err -> pure (Left err)
  Right validName -> do
    maybeGroup <- getCategoryGroup conn gid
    if maybe False isArchivedGroup maybeGroup
      then pure (Left ArchivedCategoryGroup)
      else do
        execute
          conn
          "INSERT INTO categories (group_id, name, archived_at) VALUES (?, ?, NULL)"
          (gid, validName)
        rowId <- lastInsertRowId conn
        pure (Right (unsafeReconstructCategory (CategoryId rowId) gid validName Nothing))

listCategories :: Connection -> IO [Category]
listCategories conn =
  query_ conn "SELECT id, group_id, name, archived_at FROM categories ORDER BY id"

listCategoriesInGroup :: Connection -> CategoryGroupId -> IO [Category]
listCategoriesInGroup conn gid =
  query
    conn
    "SELECT id, group_id, name, archived_at FROM categories WHERE group_id = ? ORDER BY id"
    (Only gid)

-- | Idempotent (@AND archived_at IS NULL@) — see 'Db.Account.archiveAccount'.
archiveCategory :: Connection -> CategoryId -> IO ()
archiveCategory conn cid = do
  now <- getCurrentTime
  execute conn "UPDATE categories SET archived_at = ? WHERE id = ? AND archived_at IS NULL" (now, cid)

-- | The undo for 'archiveCategory' — see 'Db.Account.unarchiveAccount'.
unarchiveCategory :: Connection -> CategoryId -> IO ()
unarchiveCategory conn cid =
  execute conn "UPDATE categories SET archived_at = NULL WHERE id = ? AND archived_at IS NOT NULL" (Only cid)
