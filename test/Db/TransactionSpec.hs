module Db.TransactionSpec (spec) where

import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Time (fromGregorian)
import Db.Account (insertAccount)
import Db.Category (insertCategory, insertCategoryGroup)
import Db.Setup (expectRight, withTestDb)
import Db.Transaction
  ( getTransaction
  , insertInflow
  , insertSpending
  , insertTransfer
  , listTransactionsForAccount
  , listTransactionsInMonth
  , reconcileAccount
  , setTransactionCleared
  )
import Domain.Account (Account (accId))
import Domain.Category (Category (catId), CategoryGroup (cgId))
import Domain.Error
  ( DomainError
      ( CategorizedTransactionRequiresOnBudgetAccount
      , TransferRequiresDistinctAccounts
      , TransferRequiresMatchingBudgetStatus
      )
  )
import Domain.Transaction
  ( Categorization (Categorized, Inflow)
  , Transaction (txCategorization, txId, txStatus)
  , TransactionLine (TransactionLine)
  , transactionAmount
  )
import Domain.Types
  ( AccountType (Checking, Tracking)
  , TransactionStatus (Cleared, Reconciled, Uncleared)
  , cents
  , mkYearMonth
  , zeroCents
  )
import Test.Hspec

spec :: Spec
spec = around withTestDb $
  describe "Db.Transaction" $ do
    it "insertInflow round-trips fully (Inflow, no category)" $ \conn -> do
      acc <- insertAccount conn "Checking Account" Checking >>= expectRight
      tx <- insertInflow conn (accId acc) (fromGregorian 2026 1 1) "Salary" Uncleared (cents 250000) Nothing
      txCategorization tx `shouldBe` Inflow (cents 250000)
      found <- getTransaction conn (txId tx)
      found `shouldBe` Just tx

    it "insertSpending with a split round-trips fully, including line order" $ \conn -> do
      acc <- insertAccount conn "Checking Account" Checking >>= expectRight
      group <- insertCategoryGroup conn "Groceries" >>= expectRight
      cat1 <- insertCategory conn (cgId group) "Supermarket" >>= expectRight
      cat2 <- insertCategory conn (cgId group) "Drugstore" >>= expectRight
      let lines' = TransactionLine (catId cat1) (cents (-3000)) :| [TransactionLine (catId cat2) (cents (-500))]
      tx <- insertSpending conn (accId acc) (fromGregorian 2026 1 5) "Supermarket" Uncleared lines' Nothing >>= expectRight
      txCategorization tx `shouldBe` Categorized lines'
      found <- getTransaction conn (txId tx)
      found `shouldBe` Just tx

    it "insertSpending on a tracking account is rejected, without adding rows" $ \conn -> do
      tracking <- insertAccount conn "Investments" Tracking >>= expectRight
      group <- insertCategoryGroup conn "Groceries" >>= expectRight
      cat <- insertCategory conn (cgId group) "Supermarket" >>= expectRight
      let lines' = TransactionLine (catId cat) (cents (-3000)) :| []
      result <- insertSpending conn (accId tracking) (fromGregorian 2026 1 5) "Supermarket" Uncleared lines' Nothing
      result `shouldBe` Left CategorizedTransactionRequiresOnBudgetAccount
      existing <- listTransactionsForAccount conn (accId tracking)
      existing `shouldBe` []

    it "insertTransfer between two on-budget accounts round-trips fully and sums to 0" $ \conn -> do
      from <- insertAccount conn "Checking Account" Checking >>= expectRight
      to <- insertAccount conn "Savings Account" Checking >>= expectRight
      (legFrom, legTo) <-
        insertTransfer conn (accId from, accId to) (fromGregorian 2026 1 10) Uncleared (cents 10000)
          >>= expectRight
      transactionAmount legFrom <> transactionAmount legTo `shouldBe` zeroCents
      foundFrom <- getTransaction conn (txId legFrom)
      foundTo <- getTransaction conn (txId legTo)
      foundFrom `shouldBe` Just legFrom
      foundTo `shouldBe` Just legTo

    it "insertTransfer to the same account is rejected, without adding rows" $ \conn -> do
      acc <- insertAccount conn "Checking Account" Checking >>= expectRight
      result <- insertTransfer conn (accId acc, accId acc) (fromGregorian 2026 1 10) Uncleared (cents 1000)
      result `shouldBe` Left TransferRequiresDistinctAccounts
      existing <- listTransactionsForAccount conn (accId acc)
      existing `shouldBe` []

    it "insertTransfer between on-budget and tracking is rejected (v0.1 limitation, DECISIONS.md §3/§7)" $ \conn -> do
      onBudget <- insertAccount conn "Checking Account" Checking >>= expectRight
      tracking <- insertAccount conn "Investments" Tracking >>= expectRight
      result <-
        insertTransfer conn (accId onBudget, accId tracking) (fromGregorian 2026 1 10) Uncleared (cents 1000)
      result `shouldBe` Left TransferRequiresMatchingBudgetStatus
      existingOnBudget <- listTransactionsForAccount conn (accId onBudget)
      existingTracking <- listTransactionsForAccount conn (accId tracking)
      existingOnBudget `shouldBe` []
      existingTracking `shouldBe` []

    it "listTransactionsInMonth filters correctly at month boundaries" $ \conn -> do
      acc <- insertAccount conn "Checking Account" Checking >>= expectRight
      _ <- insertInflow conn (accId acc) (fromGregorian 2026 1 31) "Before" Uncleared (cents 100) Nothing
      inMonth1 <- insertInflow conn (accId acc) (fromGregorian 2026 2 1) "Start" Uncleared (cents 200) Nothing
      inMonth2 <- insertInflow conn (accId acc) (fromGregorian 2026 2 28) "End" Uncleared (cents 300) Nothing
      _ <- insertInflow conn (accId acc) (fromGregorian 2026 3 1) "After" Uncleared (cents 400) Nothing
      february <- expectRight (mkYearMonth 2026 2)
      results <- listTransactionsInMonth conn february
      map txId results `shouldBe` [txId inMonth1, txId inMonth2]

    it "setTransactionCleared toggles Uncleared <-> Cleared, and is a no-op once Reconciled" $ \conn -> do
      acc <- insertAccount conn "Checking Account" Checking >>= expectRight
      tx <- insertInflow conn (accId acc) (fromGregorian 2026 1 1) "Salary" Uncleared (cents 100) Nothing
      setTransactionCleared conn (txId tx)
      afterFirstToggle <- getTransaction conn (txId tx)
      fmap txStatus afterFirstToggle `shouldBe` Just Cleared

      setTransactionCleared conn (txId tx)
      afterSecondToggle <- getTransaction conn (txId tx)
      fmap txStatus afterSecondToggle `shouldBe` Just Uncleared

      setTransactionCleared conn (txId tx) -- back to Cleared ...
      reconcileAccount conn (accId acc) -- ... and reconciled
      afterReconcile <- getTransaction conn (txId tx)
      fmap txStatus afterReconcile `shouldBe` Just Reconciled

      setTransactionCleared conn (txId tx) -- a Reconciled transaction can't be toggled
      afterToggleAttempt <- getTransaction conn (txId tx)
      fmap txStatus afterToggleAttempt `shouldBe` Just Reconciled

    it "reconcileAccount only touches Cleared transactions on that account" $ \conn -> do
      acc <- insertAccount conn "Checking Account" Checking >>= expectRight
      otherAcc <- insertAccount conn "Savings Account" Checking >>= expectRight
      cleared <- insertInflow conn (accId acc) (fromGregorian 2026 1 1) "Cleared" Uncleared (cents 100) Nothing
      stillUncleared <- insertInflow conn (accId acc) (fromGregorian 2026 1 2) "Still uncleared" Uncleared (cents 200) Nothing
      otherAccCleared <- insertInflow conn (accId otherAcc) (fromGregorian 2026 1 3) "Elsewhere" Uncleared (cents 300) Nothing
      setTransactionCleared conn (txId cleared)
      setTransactionCleared conn (txId otherAccCleared)

      reconcileAccount conn (accId acc)

      reconciledResult <- getTransaction conn (txId cleared)
      stillUnclearedResult <- getTransaction conn (txId stillUncleared)
      otherAccResult <- getTransaction conn (txId otherAccCleared)
      fmap txStatus reconciledResult `shouldBe` Just Reconciled
      fmap txStatus stillUnclearedResult `shouldBe` Just Uncleared
      fmap txStatus otherAccResult `shouldBe` Just Cleared -- untouched: different account
