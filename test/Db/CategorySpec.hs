module Db.CategorySpec (spec) where

import Db.Category
  ( archiveCategory
  , archiveCategoryGroup
  , insertCategory
  , insertCategoryGroup
  , listCategories
  , listCategoriesInGroup
  , listCategoryGroups
  , unarchiveCategory
  , unarchiveCategoryGroup
  )
import Db.Setup (expectRight, withTestDb)
import Domain.Category
  ( Category (catId, catName)
  , CategoryGroup (cgId, cgName)
  , isArchivedCategory
  , isArchivedGroup
  )
import Domain.Error (DomainError (ArchivedCategoryGroup, EmptyName))
import Test.Hspec

spec :: Spec
spec = around withTestDb $
  describe "Db.Category" $ do
    it "rejects an empty group name" $ \conn -> do
      result <- insertCategoryGroup conn ""
      result `shouldBe` Left (EmptyName "category group")

    it "round-trips a category group and the categories in it" $ \conn -> do
      group <- insertCategoryGroup conn "Fixed Costs" >>= expectRight
      cgName group `shouldBe` "Fixed Costs"
      isArchivedGroup group `shouldBe` False

      cat1 <- insertCategory conn (cgId group) "Rent" >>= expectRight
      cat2 <- insertCategory conn (cgId group) "Utilities" >>= expectRight
      catName cat1 `shouldBe` "Rent"

      inGroup <- listCategoriesInGroup conn (cgId group)
      inGroup `shouldBe` [cat1, cat2]

      allCats <- listCategories conn
      allCats `shouldBe` [cat1, cat2]

      groups <- listCategoryGroups conn
      groups `shouldBe` [group]

    it "archiveCategoryGroup/archiveCategory set archived_at" $ \conn -> do
      group <- insertCategoryGroup conn "Old Group" >>= expectRight
      cat <- insertCategory conn (cgId group) "Old Category" >>= expectRight

      archiveCategoryGroup conn (cgId group)
      archiveCategory conn (catId cat)

      groupsAfter <- listCategoryGroups conn
      catsAfter <- listCategories conn
      map isArchivedGroup groupsAfter `shouldBe` [True]
      map isArchivedCategory catsAfter `shouldBe` [True]

    it "unarchiveCategoryGroup/unarchiveCategory clear archived_at" $ \conn -> do
      group <- insertCategoryGroup conn "Old Group" >>= expectRight
      cat <- insertCategory conn (cgId group) "Old Category" >>= expectRight
      archiveCategoryGroup conn (cgId group)
      archiveCategory conn (catId cat)

      unarchiveCategoryGroup conn (cgId group)
      unarchiveCategory conn (catId cat)

      groupsAfter <- listCategoryGroups conn
      catsAfter <- listCategories conn
      map isArchivedGroup groupsAfter `shouldBe` [False]
      map isArchivedCategory catsAfter `shouldBe` [False]

    it "rejects a new category in an already-archived group" $ \conn -> do
      group <- insertCategoryGroup conn "Old Group" >>= expectRight
      archiveCategoryGroup conn (cgId group)
      result <- insertCategory conn (cgId group) "Rent"
      result `shouldBe` Left ArchivedCategoryGroup
      inGroup <- listCategoriesInGroup conn (cgId group)
      inGroup `shouldBe` []
