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
  describe "rolloverCategoryMonth (invariant 4: conservation of money at the month rollover)" $ do
    it "never loses or creates money: carry <> rtaAdjustment == available" $
      property $ \cm ->
        let r = rolloverCategoryMonth cm
        in rolloverCarry r <> rolloverRtaAdjustment r == available cm

    it "carry is never negative" $
      property $ \cm -> rolloverCarry (rolloverCategoryMonth cm) >= zeroCents

    it "the Ready to Assign adjustment is never positive" $
      property $ \cm -> rolloverRtaAdjustment (rolloverCategoryMonth cm) <= zeroCents

    it "a non-negative balance carries forward unchanged, with no RTA impact" $
      property $ \cm ->
        available cm >= zeroCents ==>
          rolloverCategoryMonth cm === Rollover (available cm) zeroCents

    it "a negative balance resets to 0 and the whole shortfall goes to Ready to Assign" $
      property $ \cm ->
        available cm < zeroCents ==>
          rolloverCategoryMonth cm === Rollover zeroCents (available cm)

  describe "accountBalance" $
    it "a transaction only ever affects the balance of its own account" $
      property $ \tx otherAcc ->
        otherAcc /= txAccount tx ==>
          accountBalance (txAccount tx) [tx] == transactionAmount tx
            && accountBalance otherAcc [tx] == zeroCents

  describe "budgetBalancesAccounts (invariant 1: the ledger balances)" $
    it "on-budget account balances == category balances + Ready to Assign" $
      forAll genWorld $ \w ->
        let categoryMonths =
              [ buildCategoryMonth (wAccounts w) (catId c) (wMonth w) zeroCents (wAssignments w) (wTransactions w)
              | c <- wCategories w
              ]
            rta = readyToAssign zeroCents (wAccounts w) (wMonth w) (wAssignments w) (wTransactions w)
        in budgetBalancesAccounts (wAccounts w) categoryMonths rta (wTransactions w)
