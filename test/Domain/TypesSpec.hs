module Domain.TypesSpec (spec) where

import Data.List.NonEmpty (toList)
import Domain.Error (DomainError (..))
import Domain.Gen (genDayIn, genYearMonth)
import Domain.Types
import Test.Hspec
import Test.QuickCheck

spec :: Spec
spec = do
  describe "Cents" $ do
    it "zeroCents is the identity for <>" $
      property $ \c -> (c <> zeroCents) == c && (zeroCents <> c) == c

    it "negateCents is its own inverse" $
      property $ \c -> negateCents (negateCents c) == c

    it "c <> negateCents c == zeroCents" $
      property $ \c -> (c <> negateCents c) == zeroCents

  describe "splitEvenly (invariant 3, generic form)" $ do
    it "always sums back to the original" $
      property $ \amount n -> mconcat (toList (splitEvenly amount n)) == amount

    it "has exactly 'max 1 n' lines" $
      property $ \amount n -> length (toList (splitEvenly amount n)) == max 1 n

  describe "mkYearMonth" $ do
    it "rejects months outside [1,12] with InvalidMonth" $
      property $ \y m ->
        (m < 1 || m > 12) ==>
          mkYearMonth y m == Left (InvalidMonth m)

    it "accepts every month within [1,12]" $
      property $ \y m ->
        let m' = 1 + (m `mod` 12) -- always in [1,12], even for negative/extreme m
        in case mkYearMonth y m' of
             Right ym -> ymMonth ym == m' && ymYear ym == y
             Left _   -> False

  describe "nextYearMonth / prevYearMonth" $
    it "are each other's inverse" $
      property $ \ym -> prevYearMonth (nextYearMonth ym) == ym

  describe "dayToYearMonth" $
    it "matches the month a day was generated for" $
      property $
        forAll genYearMonth $ \ym ->
          forAll (genDayIn ym) $ \day ->
            dayToYearMonth day === ym

  describe "yearMonthToText / parseYearMonth" $ do
    it "round-trips through every YearMonth Domain.Gen produces" $
      property $ \ym -> parseYearMonth (yearMonthToText ym) == Just ym

    it "formats as YYYY-MM" $
      case mkYearMonth 2026 3 of
        Right ym -> yearMonthToText ym `shouldBe` "2026-03"
        Left _   -> expectationFailure "mkYearMonth 2026 3 should succeed"

    it "rejects garbage" $
      parseYearMonth "not-a-month" `shouldBe` Nothing

    it "rejects a month outside [1,12]" $
      parseYearMonth "2026-13" `shouldBe` Nothing

  describe "toggleCleared" $ do
    it "is its own inverse" $
      property $ \s -> toggleCleared (toggleCleared s) == s

    it "never changes a Reconciled status (reconciling is an account-wide action, not a per-row toggle)" $
      toggleCleared Reconciled `shouldBe` Reconciled
