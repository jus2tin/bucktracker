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
    it "wijst een lege (of enkel whitespace) naam af" $
      mkAccount (AccountId 1) "   " Checking `shouldBe` Left (EmptyName "account")

    it "accepteert elke niet-lege naam" $
      property $ \ty ->
        case mkAccount (AccountId 1) "Betaalrekening" ty of
          Right acc -> accName acc == "Betaalrekening" && accType acc == ty
          Left _    -> False

  describe "isOnBudget" $
    it "is waar voor elk AccountType behalve Tracking" $
      property $ \ty -> isOnBudgetType ty == (ty /= Tracking)

  describe "sameBudgetStatus" $
    it "komt overeen met isOnBudget op beide rekeningen" $
      property $ \ta tb ->
        case (mkAccount (AccountId 1) "A" ta, mkAccount (AccountId 2) "B" tb) of
          (Right a, Right b) -> sameBudgetStatus a b == (isOnBudget a == isOnBudget b)
          _                  -> False
