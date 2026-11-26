module Domain.AccountSpec (spec) where

import Domain.Account
import Domain.Error (DomainError (..))
import Domain.Gen ()
import Domain.Types
import Test.Hspec
import Test.QuickCheck

spec :: Spec
spec = do
  describe "mkAccount" $ do
    it "rejects an empty (or whitespace-only) name" $
      mkAccount (AccountId 1) "   " Checking `shouldBe` Left (EmptyName "account")

    it "accepts every non-empty name" $
      property $ \ty ->
        case mkAccount (AccountId 1) "Checking Account" ty of
          Right acc -> accName acc == "Checking Account" && accType acc == ty
          Left _    -> False

  describe "isOnBudget" $
    it "is true for every AccountType except Tracking" $
      property $ \ty -> isOnBudgetType ty == (ty /= Tracking)

  describe "sameBudgetStatus" $
    it "matches isOnBudget on both accounts" $
      property $ \ta tb ->
        case (mkAccount (AccountId 1) "A" ta, mkAccount (AccountId 2) "B" tb) of
          (Right a, Right b) -> sameBudgetStatus a b == (isOnBudget a == isOnBudget b)
          _                  -> False
