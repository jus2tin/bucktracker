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

  describe "splitEvenly (invariant 3, generieke vorm)" $ do
    it "sommeert altijd terug naar het origineel" $
      property $ \amount n -> mconcat (toList (splitEvenly amount n)) == amount

    it "heeft precies 'max 1 n' regels" $
      property $ \amount n -> length (toList (splitEvenly amount n)) == max 1 n

  describe "mkYearMonth" $ do
    it "wijst maanden buiten [1,12] af met InvalidMonth" $
      property $ \y m ->
        (m < 1 || m > 12) ==>
          mkYearMonth y m == Left (InvalidMonth m)

    it "accepteert elke maand binnen [1,12]" $
      property $ \y m ->
        let m' = 1 + (m `mod` 12) -- altijd in [1,12], ook voor negatieve/extreme m
        in case mkYearMonth y m' of
             Right ym -> ymMonth ym == m' && ymYear ym == y
             Left _   -> False

  describe "nextYearMonth / prevYearMonth" $
    it "zijn elkaars inverse" $
      property $ \ym -> prevYearMonth (nextYearMonth ym) == ym

  describe "dayToYearMonth" $
    it "komt overeen met de maand waarvoor de dag is gegenereerd" $
      property $
        forAll genYearMonth $ \ym ->
          forAll (genDayIn ym) $ \day ->
            dayToYearMonth day === ym
