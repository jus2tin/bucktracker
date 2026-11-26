module Domain.BudgetSpec (spec) where

import Domain.Budget
import Domain.Category (catId)
import Domain.Gen
import Domain.Transaction (transactionAmount, txAccount)
import Domain.Types
import Test.Hspec
import Test.QuickCheck

spec :: Spec
spec = do
  describe "rolloverCategoryMonth (invariant 4: behoud van geld bij de maandovergang)" $ do
    it "verliest of creëert nooit geld: carry <> rtaAdjustment == available" $
      property $ \cm ->
        let r = rolloverCategoryMonth cm
        in rolloverCarry r <> rolloverRtaAdjustment r == available cm

    it "carry is nooit negatief" $
      property $ \cm -> rolloverCarry (rolloverCategoryMonth cm) >= zeroCents

    it "de Ready to Assign-aanpassing is nooit positief" $
      property $ \cm -> rolloverRtaAdjustment (rolloverCategoryMonth cm) <= zeroCents

    it "een niet-negatief saldo rolt ongewijzigd door, zonder RTA-impact" $
      property $ \cm ->
        available cm >= zeroCents ==>
          rolloverCategoryMonth cm === Rollover (available cm) zeroCents

    it "een negatief saldo reset naar 0 en het hele tekort gaat naar Ready to Assign" $
      property $ \cm ->
        available cm < zeroCents ==>
          rolloverCategoryMonth cm === Rollover zeroCents (available cm)

  describe "accountBalance" $
    it "een transactie raakt alleen het saldo van zijn eigen rekening" $
      property $ \tx otherAcc ->
        otherAcc /= txAccount tx ==>
          accountBalance (txAccount tx) [tx] == transactionAmount tx
            && accountBalance otherAcc [tx] == zeroCents

  describe "budgetBalancesAccounts (invariant 1: de boekhouding klopt)" $
    it "on-budget rekeningsaldi == categoriesaldi + Ready to Assign" $
      forAll genWorld $ \w ->
        let categoryMonths =
              [ buildCategoryMonth (catId c) (wMonth w) zeroCents (wAssignments w) (wTransactions w)
              | c <- wCategories w
              ]
            rta = readyToAssign zeroCents (wAccounts w) (wMonth w) (wAssignments w) (wTransactions w)
        in budgetBalancesAccounts (wAccounts w) categoryMonths rta (wTransactions w)
