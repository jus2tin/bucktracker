module Domain.ValidationSpec (spec) where

import qualified Data.Text as Text
import Domain.Error (DomainError (EmptyName, InvalidCharacters, NameTooLong))
import Domain.Validation (nonEmptyName, validatePayee)
import Test.Hspec

spec :: Spec
spec = do
  describe "nonEmptyName (AUDIT-08)" $ do
    it "rejects an empty or whitespace-only name" $
      nonEmptyName "account" "   " `shouldBe` Left (EmptyName "account")

    it "trims surrounding whitespace from an otherwise valid name" $
      nonEmptyName "account" "  Checking  " `shouldBe` Right "Checking"

    it "rejects a name containing a control character" $
      nonEmptyName "account" "Checking\t1" `shouldBe` Left (InvalidCharacters "account")

    it "rejects a name longer than 80 characters" $
      nonEmptyName "account" (Text.replicate 81 "x") `shouldBe` Left (NameTooLong "account" 80)

    it "accepts a name exactly 80 characters long" $
      nonEmptyName "account" (Text.replicate 80 "x") `shouldBe` Right (Text.replicate 80 "x")

  describe "validatePayee (AUDIT-08)" $ do
    it "trims surrounding whitespace" $
      validatePayee "  Supermarket  " `shouldBe` Right "Supermarket"

    it "allows an empty payee" $
      validatePayee "   " `shouldBe` Right ""

    it "rejects a payee containing a control character" $
      validatePayee "Super\nmarket" `shouldBe` Left (InvalidCharacters "payee")

    it "rejects a payee longer than 160 characters" $
      validatePayee (Text.replicate 161 "x") `shouldBe` Left (NameTooLong "payee" 160)

    it "accepts a payee exactly 160 characters long" $
      validatePayee (Text.replicate 160 "x") `shouldBe` Right (Text.replicate 160 "x")
