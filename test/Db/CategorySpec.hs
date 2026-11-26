module Db.CategorySpec (spec) where

import Db.Category
  ( archiveCategory
  , archiveCategoryGroup
  , insertCategory
  , insertCategoryGroup
  , listCategories
  , listCategoriesInGroup
  , listCategoryGroups
  )
import Db.Setup (expectRight, withTestDb)
import Domain.Category
  ( Category (catId, catName)
  , CategoryGroup (cgId, cgName)
  , isArchivedCategory
  , isArchivedGroup
  )
import Domain.Error (DomainError (EmptyName))
import Test.Hspec

spec :: Spec
spec = around withTestDb $
  describe "Db.Category" $ do
    it "wijst een lege groepsnaam af" $ \conn -> do
      result <- insertCategoryGroup conn ""
      result `shouldBe` Left (EmptyName "category group")

    it "rondt een categoriegroep en de categorieën erin volledig" $ \conn -> do
      group <- insertCategoryGroup conn "Vaste lasten" >>= expectRight
      cgName group `shouldBe` "Vaste lasten"
      isArchivedGroup group `shouldBe` False

      cat1 <- insertCategory conn (cgId group) "Huur" >>= expectRight
      cat2 <- insertCategory conn (cgId group) "Energie" >>= expectRight
      catName cat1 `shouldBe` "Huur"

      inGroup <- listCategoriesInGroup conn (cgId group)
      inGroup `shouldBe` [cat1, cat2]

      allCats <- listCategories conn
      allCats `shouldBe` [cat1, cat2]

      groups <- listCategoryGroups conn
      groups `shouldBe` [group]

    it "archiveCategoryGroup/archiveCategory zetten archived_at" $ \conn -> do
      group <- insertCategoryGroup conn "Oude groep" >>= expectRight
      cat <- insertCategory conn (cgId group) "Oude categorie" >>= expectRight

      archiveCategoryGroup conn (cgId group)
      archiveCategory conn (catId cat)

      groupsAfter <- listCategoryGroups conn
      catsAfter <- listCategories conn
      map isArchivedGroup groupsAfter `shouldBe` [True]
      map isArchivedCategory catsAfter `shouldBe` [True]
