module Domain.Category
  ( CategoryGroup
  , cgId
  , cgName
  , cgArchivedAt
  , mkCategoryGroup
  , unsafeReconstructCategoryGroup
  , Category
  , catId
  , catGroupId
  , catName
  , catArchivedAt
  , mkCategory
  , unsafeReconstructCategory
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

-- | Rebuilds a 'CategoryGroup' from data that's already valid — see
-- 'Domain.Account.unsafeReconstructAccount' for why this exists instead
-- of exporting the raw constructor (DECISIONS.md §8, M-10).
unsafeReconstructCategoryGroup :: CategoryGroupId -> Text -> Maybe UTCTime -> CategoryGroup
unsafeReconstructCategoryGroup = CategoryGroup

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

-- | Rebuilds a 'Category' from data that's already valid — see
-- 'Domain.Account.unsafeReconstructAccount' for why this exists instead
-- of exporting the raw constructor (DECISIONS.md §8, M-10).
unsafeReconstructCategory :: CategoryId -> CategoryGroupId -> Text -> Maybe UTCTime -> Category
unsafeReconstructCategory = Category

isArchivedCategory :: Category -> Bool
isArchivedCategory cat = case catArchivedAt cat of
  Just _  -> True
  Nothing -> False
