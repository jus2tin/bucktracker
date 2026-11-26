module Domain.Category
  ( CategoryGroup (..)
  , mkCategoryGroup
  , Category (..)
  , mkCategory
  ) where

import Data.Text (Text)
import qualified Data.Text as Text
import Domain.Error (DomainError (..))
import Domain.Types (CategoryGroupId, CategoryId)

data CategoryGroup = CategoryGroup
  { cgId   :: CategoryGroupId
  , cgName :: Text
  } deriving stock (Eq, Show)

mkCategoryGroup :: CategoryGroupId -> Text -> Either DomainError CategoryGroup
mkCategoryGroup gid name
  | Text.null (Text.strip name) = Left (EmptyName "category group")
  | otherwise = Right (CategoryGroup gid name)

-- | Een categorie, altijd onderdeel van precies één 'CategoryGroup'
-- (twee niveaus, zie DECISIONS.md §3).
data Category = Category
  { catId      :: CategoryId
  , catGroupId :: CategoryGroupId
  , catName    :: Text
  } deriving stock (Eq, Show)

mkCategory :: CategoryId -> CategoryGroupId -> Text -> Either DomainError Category
mkCategory cid gid name
  | Text.null (Text.strip name) = Left (EmptyName "category")
  | otherwise = Right (Category cid gid name)
