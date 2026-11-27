module Db.TransactionSpec (spec) where

import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Time (fromGregorian)
import Db.Account (insertAccount)
import Db.Category (insertCategory, insertCategoryGroup)
import Db.Setup (expectRight, withTestDb)
import Db.Transaction
  ( deleteTransaction
  , getTransaction
  , insertInflow
  , insertSpending
  , insertTransfer
  , listTransactionsForAccount
  , listTransactionsInMonth
  , reconcileAccount
  , setTransactionCleared
  , updateInflow
  , updateSpending
  , updateTransfer
  )
import Domain.Account (Account (accId))
import Domain.Category (Category (catId), CategoryGroup (cgId))
import Domain.Error
  ( DomainError
      ( CannotModifyReconciledTransaction
      , CategorizedTransactionRequiresOnBudgetAccount
      , TransferRequiresDistinctAccounts
      , TransferRequiresMatchingBudgetStatus
      )
  )
import Domain.Transaction
  ( Categorization (Categorized, Inflow)
  , Transaction (txAccount, txCategorization, txId, txPayee, txStatus)
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

    it "deleteTransaction removes a plain inflow, and is a no-op on an unknown id" $ \conn -> do
      acc <- insertAccount conn "Checking Account" Checking >>= expectRight
      tx <- insertInflow conn (accId acc) (fromGregorian 2026 1 1) "Salary" Uncleared (cents 100) Nothing
      result <- deleteTransaction conn (txId tx)
      result `shouldBe` Right ()
      getTransaction conn (txId tx) >>= (`shouldBe` Nothing)

      noopResult <- deleteTransaction conn (txId tx)
      noopResult `shouldBe` Right ()

    it "deleteTransaction removes both legs of a transfer" $ \conn -> do
      from <- insertAccount conn "Checking Account" Checking >>= expectRight
      to <- insertAccount conn "Savings Account" Checking >>= expectRight
      (legFrom, legTo) <-
        insertTransfer conn (accId from, accId to) (fromGregorian 2026 1 10) Uncleared (cents 10000)
          >>= expectRight
      result <- deleteTransaction conn (txId legFrom)
      result `shouldBe` Right ()
      getTransaction conn (txId legFrom) >>= (`shouldBe` Nothing)
      getTransaction conn (txId legTo) >>= (`shouldBe` Nothing)

    it "deleteTransaction is blocked on an already-Reconciled transaction" $ \conn -> do
      acc <- insertAccount conn "Checking Account" Checking >>= expectRight
      tx <- insertInflow conn (accId acc) (fromGregorian 2026 1 1) "Salary" Uncleared (cents 100) Nothing
      setTransactionCleared conn (txId tx)
      reconcileAccount conn (accId acc)
      result <- deleteTransaction conn (txId tx)
      result `shouldBe` Left CannotModifyReconciledTransaction
      afterAttempt <- getTransaction conn (txId tx)
      fmap txStatus afterAttempt `shouldBe` Just Reconciled

    it "updateInflow replaces the fields in place, preserving status, and leaves nothing stale behind" $ \conn -> do
      acc <- insertAccount conn "Checking Account" Checking >>= expectRight
      otherAcc <- insertAccount conn "Savings Account" Checking >>= expectRight
      tx <- insertInflow conn (accId acc) (fromGregorian 2026 1 1) "Salary" Uncleared (cents 100) Nothing
      setTransactionCleared conn (txId tx)
      result <-
        updateInflow conn (txId tx) (accId otherAcc) (fromGregorian 2026 1 5) "Corrected Salary" (cents 200)
      case result of
        Right (Just edited) -> do
          txAccount edited `shouldBe` accId otherAcc
          txPayee edited `shouldBe` "Corrected Salary"
          txCategorization edited `shouldBe` Inflow (cents 200)
          txStatus edited `shouldBe` Cleared
        _ -> expectationFailure ("expected Right (Just _), got " <> show result)
      -- the old account keeps no trace of it (not even under a reused id —
      -- SQLite's rowid allocator can reuse a deleted row's id, so "the old
      -- id resolves to Nothing" isn't a safe assertion here)
      listTransactionsForAccount conn (accId acc) >>= (`shouldBe` [])

    it "updateInflow is blocked on an already-Reconciled transaction, without changing it" $ \conn -> do
      acc <- insertAccount conn "Checking Account" Checking >>= expectRight
      tx <- insertInflow conn (accId acc) (fromGregorian 2026 1 1) "Salary" Uncleared (cents 100) Nothing
      setTransactionCleared conn (txId tx)
      reconcileAccount conn (accId acc)
      result <- updateInflow conn (txId tx) (accId acc) (fromGregorian 2026 1 1) "Changed" (cents 999)
      result `shouldBe` Left CannotModifyReconciledTransaction
      afterAttempt <- getTransaction conn (txId tx)
      fmap txPayee afterAttempt `shouldBe` Just "Salary"

    it "updateSpending replaces the split lines in place" $ \conn -> do
      acc <- insertAccount conn "Checking Account" Checking >>= expectRight
      group <- insertCategoryGroup conn "Groceries" >>= expectRight
      cat1 <- insertCategory conn (cgId group) "Supermarket" >>= expectRight
      cat2 <- insertCategory conn (cgId group) "Drugstore" >>= expectRight
      let original = TransactionLine (catId cat1) (cents (-3000)) :| []
      tx <- insertSpending conn (accId acc) (fromGregorian 2026 1 5) "Supermarket" Uncleared original Nothing >>= expectRight
      let edited' = TransactionLine (catId cat1) (cents (-1000)) :| [TransactionLine (catId cat2) (cents (-500))]
      result <- updateSpending conn (txId tx) (accId acc) (fromGregorian 2026 1 6) "Corrected" edited'
      case result of
        Right (Just edited) -> txCategorization edited `shouldBe` Categorized edited'
        _ -> expectationFailure ("expected Right (Just _), got " <> show result)
      -- exactly one transaction on the account now, with the edited lines
      -- (not the original lines still sitting there alongside it)
      remaining <- listTransactionsForAccount conn (accId acc)
      map txCategorization remaining `shouldBe` [Categorized edited']

    it "updateSpending onto a tracking account is rejected, without changing the original" $ \conn -> do
      acc <- insertAccount conn "Checking Account" Checking >>= expectRight
      tracking <- insertAccount conn "Investments" Tracking >>= expectRight
      group <- insertCategoryGroup conn "Groceries" >>= expectRight
      cat <- insertCategory conn (cgId group) "Supermarket" >>= expectRight
      let lines' = TransactionLine (catId cat) (cents (-3000)) :| []
      tx <- insertSpending conn (accId acc) (fromGregorian 2026 1 5) "Supermarket" Uncleared lines' Nothing >>= expectRight
      result <- updateSpending conn (txId tx) (accId tracking) (fromGregorian 2026 1 5) "Supermarket" lines'
      result `shouldBe` Left CategorizedTransactionRequiresOnBudgetAccount
      afterAttempt <- getTransaction conn (txId tx)
      fmap txCategorization afterAttempt `shouldBe` Just (Categorized lines')

    it "updateTransfer replaces both legs, accounts, and amount together" $ \conn -> do
      from <- insertAccount conn "Checking Account" Checking >>= expectRight
      to <- insertAccount conn "Savings Account" Checking >>= expectRight
      other <- insertAccount conn "Cash" Checking >>= expectRight
      (legFrom, legTo) <-
        insertTransfer conn (accId from, accId to) (fromGregorian 2026 1 10) Uncleared (cents 10000)
          >>= expectRight
      result <- updateTransfer conn (txId legFrom) (accId from, accId other) (fromGregorian 2026 1 11) (cents 5000)
      case result of
        Right (Just (editedFrom, editedTo)) -> do
          txAccount editedFrom `shouldBe` accId from
          txAccount editedTo `shouldBe` accId other
          transactionAmount editedFrom <> transactionAmount editedTo `shouldBe` zeroCents
          transactionAmount editedFrom `shouldBe` cents (-5000)
        _ -> expectationFailure ("expected Right (Just _), got " <> show result)
      -- the original "to" account (Savings) keeps no trace of the old leg
      listTransactionsForAccount conn (accId to) >>= (`shouldBe` [])
