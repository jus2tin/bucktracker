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
    it "wijst een lege naam af" $
      mkCategoryGroup (CategoryGroupId 1) "" `shouldBe` Left (EmptyName "category group")

    it "accepteert elke niet-lege naam" $
      property $ \gid ->
        case mkCategoryGroup gid "Vaste lasten" of
          Right cg -> cgName cg == "Vaste lasten" && cgId cg == gid
          Left _   -> False

  describe "mkCategory" $ do
    it "wijst een lege naam af" $
      mkCategory (CategoryId 1) (CategoryGroupId 1) "  " `shouldBe` Left (EmptyName "category")

    it "hangt altijd aan exact de gegeven groep" $
      property $ \cid gid ->
        case mkCategory cid gid "Boodschappen" of
          Right cat -> catGroupId cat == gid && catId cat == cid
          Left _    -> False
