module Domain.CategorySpec (spec) where

import Domain.Category
import Domain.Error (DomainError (..))
import Domain.Gen ()
import Domain.Types (CategoryGroupId (..), CategoryId (..))
import Test.Hspec
import Test.QuickCheck

spec :: Spec
spec = do
  describe "mkCategoryGroup" $ do
    it "rejects an empty name" $
      mkCategoryGroup (CategoryGroupId 1) "" `shouldBe` Left (EmptyName "category group")

    it "accepts every non-empty name" $
      property $ \gid ->
        case mkCategoryGroup gid "Fixed Costs" of
          Right cg -> cgName cg == "Fixed Costs" && cgId cg == gid
          Left _   -> False

  describe "mkCategory" $ do
    it "rejects an empty name" $
      mkCategory (CategoryId 1) (CategoryGroupId 1) "  " `shouldBe` Left (EmptyName "category")

    it "always belongs to exactly the given group" $
      property $ \cid gid ->
        case mkCategory cid gid "Groceries" of
          Right cat -> catGroupId cat == gid && catId cat == cid
          Left _    -> False
