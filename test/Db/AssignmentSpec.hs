module Db.AssignmentSpec (spec) where

import Db.Assignment (listAssignmentsForMonth, setAssignment)
import Db.Category (insertCategory, insertCategoryGroup)
import Db.Setup (expectRight, withTestDb)
import Domain.Budget (Assignment (asgAmount, asgCategory))
import Domain.Category (Category (catId), CategoryGroup (cgId))
import Domain.Types (cents, mkYearMonth)
import Test.Hspec

spec :: Spec
spec = around withTestDb $
  describe "Db.Assignment" $ do
    it "rondt een toewijzing volledig" $ \conn -> do
      group <- insertCategoryGroup conn "Vaste lasten" >>= expectRight
      cat <- insertCategory conn (cgId group) "Huur" >>= expectRight
      january <- expectRight (mkYearMonth 2026 1)
      setAssignment conn (catId cat) january (cents 90000)
      results <- listAssignmentsForMonth conn january
      map asgCategory results `shouldBe` [catId cat]
      map asgAmount results `shouldBe` [cents 90000]

    it "is een upsert: opnieuw zetten overschrijft, voegt geen rij toe" $ \conn -> do
      group <- insertCategoryGroup conn "Vaste lasten" >>= expectRight
      cat <- insertCategory conn (cgId group) "Huur" >>= expectRight
      january <- expectRight (mkYearMonth 2026 1)
      setAssignment conn (catId cat) january (cents 90000)
      setAssignment conn (catId cat) january (cents 95000)
      results <- listAssignmentsForMonth conn january
      map asgAmount results `shouldBe` [cents 95000]
