module Api.MoneySpec (spec) where

import Api.Money (centsToEuroText, parseNonZeroSignedEuros, parsePositiveEuros, parseSignedEuros)
import Domain.Gen ()
import Domain.Types (cents, zeroCents)
import Test.Hspec
import Test.QuickCheck

spec :: Spec
spec = do
  describe "parseSignedEuros" $ do
    it "parses a plain positive amount" $
      parseSignedEuros "12.34" `shouldBe` Just (cents 1234)

    it "parses a negative amount with a leading -" $
      parseSignedEuros "-25.50" `shouldBe` Just (cents (-2550))

    it "accepts a comma as the decimal separator" $
      parseSignedEuros "12,34" `shouldBe` Just (cents 1234)

    it "accepts a negative comma-decimal amount" $
      parseSignedEuros "-12,34" `shouldBe` Just (cents (-1234))

    it "accepts a whole-euro amount with no decimal part" $
      parseSignedEuros "12" `shouldBe` Just (cents 1200)

    it "accepts a single decimal digit, padded to two" $
      parseSignedEuros "12.5" `shouldBe` Just (cents 1250)

    it "rejects garbage" $
      parseSignedEuros "not a number" `shouldBe` Nothing

    it "rejects an empty string" $
      parseSignedEuros "" `shouldBe` Nothing

    it "rejects a whole-euro amount over the 100 billion bound, instead of silently overflowing Int64" $
      -- 10^17 euros: previously accepted, then 'whole * 100' overflowed
      -- Int64 (Architect review S-2).
      parseSignedEuros "100000000000000000" `shouldBe` Nothing

    it "accepts exactly the 100 billion euro bound" $
      parseSignedEuros "100000000000" `shouldBe` Just (cents 10000000000000)

    it "rejects one euro over the bound" $
      parseSignedEuros "100000000001" `shouldBe` Nothing

  describe "parseNonZeroSignedEuros" $ do
    it "rejects a zero amount" $ do
      parseNonZeroSignedEuros "0" `shouldBe` Nothing
      parseNonZeroSignedEuros "0.00" `shouldBe` Nothing
      parseNonZeroSignedEuros "-0.00" `shouldBe` Nothing

    it "accepts any non-zero signed amount" $
      parseNonZeroSignedEuros "-5.00" `shouldBe` Just (cents (-500))

  describe "parsePositiveEuros" $ do
    it "rejects zero" $
      parsePositiveEuros "0.00" `shouldBe` Nothing

    it "rejects a negative amount" $
      parsePositiveEuros "-5.00" `shouldBe` Nothing

    it "accepts a positive amount" $
      parsePositiveEuros "5.00" `shouldBe` Just (cents 500)

  describe "centsToEuroText" $ do
    it "formats a positive amount" $
      centsToEuroText (cents 1234) `shouldBe` "12.34"

    it "formats a negative amount with a single leading -" $
      centsToEuroText (cents (-2550)) `shouldBe` "-25.50"

    it "formats zero" $
      centsToEuroText zeroCents `shouldBe` "0.00"

    it "formats Int64's minBound cleanly, instead of the two's-complement 'abs minBound == minBound' corruption" $
      -- Before going through Integer, this used to format as
      -- "--92233720368547759.92"-style nonsense.
      centsToEuroText (cents minBound) `shouldBe` "-92233720368547758.08"

    it "round-trips through parseSignedEuros for every amount Domain.Gen produces (well within the parser's bound)" $
      property $ \c -> parseSignedEuros (centsToEuroText c) == Just c
