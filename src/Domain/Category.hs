module Domain.Category
  ( CategoryGroup (..)
  , mkCategoryGroup
  , Category (..)
  , mkCategory
  , isArchivedGroup
  , isArchivedCategory
  ) where

import Data.Text (Text)
import Data.Time (UTCTime)
import Domain.Error (DomainError)
import Domain.Types (CategoryGroupId, CategoryId)
import Domain.Validation (nonEmptyName)

-- | 'cgArchivedAt': soft delete (DECISIONS.md §7), same as 'Domain.Account.Account'.
data CategoryGroup = CategoryGroup
  { cgId         :: CategoryGroupId
  , cgName       :: Text
  , cgArchivedAt :: Maybe UTCTime
  } deriving stock (Eq, Show)

mkCategoryGroup :: CategoryGroupId -> Text -> Either DomainError CategoryGroup
mkCategoryGroup gid name =
  (\n -> CategoryGroup gid n Nothing) <$> nonEmptyName "category group" name

isArchivedGroup :: CategoryGroup -> Bool
isArchivedGroup cg = case cgArchivedAt cg of
  Just _  -> True
  Nothing -> False

-- | A category, always part of exactly one 'CategoryGroup' (two levels,
-- see DECISIONS.md §3).
data Category = Category
  { catId         :: CategoryId
  , catGroupId    :: CategoryGroupId
  , catName       :: Text
  , catArchivedAt :: Maybe UTCTime
  } deriving stock (Eq, Show)

mkCategory :: CategoryId -> CategoryGroupId -> Text -> Either DomainError Category
mkCategory cid gid name =
  (\n -> Category cid gid n Nothing) <$> nonEmptyName "category" name

isArchivedCategory :: Category -> Bool
isArchivedCategory cat = case catArchivedAt cat of
  Just _  -> True
  Nothing -> False
