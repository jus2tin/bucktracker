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
  )
import Domain.Account (Account (accId))
import Domain.Category (Category (catId), CategoryGroup (cgId))
import Domain.Error (DomainError (TransferRequiresDistinctAccounts, TransferRequiresMatchingBudgetStatus))
import Domain.Transaction
  ( Categorization (Categorized, Inflow)
  , Transaction (txCategorization, txId)
  , TransactionLine (TransactionLine)
  , transactionAmount
  )
import Domain.Types
  ( AccountType (Checking, Tracking)
  , TransactionStatus (Uncleared)
  , cents
  , mkYearMonth
  , zeroCents
  )
import Test.Hspec

spec :: Spec
spec = around withTestDb $
  describe "Db.Transaction" $ do
    it "insertInflow rondt volledig (Inflow, geen categorie)" $ \conn -> do
      acc <- insertAccount conn "Betaalrekening" Checking >>= expectRight
      tx <- insertInflow conn (accId acc) (fromGregorian 2026 1 1) "Salaris" Uncleared (cents 250000) Nothing
      txCategorization tx `shouldBe` Inflow (cents 250000)
      found <- getTransaction conn (txId tx)
      found `shouldBe` Just tx

    it "insertSpending met een split rondt volledig, inclusief regelvolgorde" $ \conn -> do
      acc <- insertAccount conn "Betaalrekening" Checking >>= expectRight
      group <- insertCategoryGroup conn "Boodschappen" >>= expectRight
      cat1 <- insertCategory conn (cgId group) "Supermarkt" >>= expectRight
      cat2 <- insertCategory conn (cgId group) "Drogist" >>= expectRight
      let lines' = TransactionLine (catId cat1) (cents (-3000)) :| [TransactionLine (catId cat2) (cents (-500))]
      tx <- insertSpending conn (accId acc) (fromGregorian 2026 1 5) "Supermarkt" Uncleared lines' Nothing
      txCategorization tx `shouldBe` Categorized lines'
      found <- getTransaction conn (txId tx)
      found `shouldBe` Just tx

    it "insertTransfer tussen twee on-budget rekeningen rondt volledig en sommeert naar 0" $ \conn -> do
      from <- insertAccount conn "Betaalrekening" Checking >>= expectRight
      to <- insertAccount conn "Spaarrekening" Checking >>= expectRight
      (legFrom, legTo) <-
        insertTransfer conn (accId from, accId to) (fromGregorian 2026 1 10) Uncleared (cents 10000)
          >>= expectRight
      transactionAmount legFrom <> transactionAmount legTo `shouldBe` zeroCents
      foundFrom <- getTransaction conn (txId legFrom)
      foundTo <- getTransaction conn (txId legTo)
      foundFrom `shouldBe` Just legFrom
      foundTo `shouldBe` Just legTo

    it "insertTransfer naar dezelfde rekening wijst af, zonder rijen toe te voegen" $ \conn -> do
      acc <- insertAccount conn "Betaalrekening" Checking >>= expectRight
      result <- insertTransfer conn (accId acc, accId acc) (fromGregorian 2026 1 10) Uncleared (cents 1000)
      result `shouldBe` Left TransferRequiresDistinctAccounts
      existing <- listTransactionsForAccount conn (accId acc)
      existing `shouldBe` []

    it "insertTransfer tussen on-budget en tracking wijst af (v0.1-beperking, DECISIONS.md §3/§7)" $ \conn -> do
      onBudget <- insertAccount conn "Betaalrekening" Checking >>= expectRight
      tracking <- insertAccount conn "Beleggingen" Tracking >>= expectRight
      result <-
        insertTransfer conn (accId onBudget, accId tracking) (fromGregorian 2026 1 10) Uncleared (cents 1000)
      result `shouldBe` Left TransferRequiresMatchingBudgetStatus
      existingOnBudget <- listTransactionsForAccount conn (accId onBudget)
      existingTracking <- listTransactionsForAccount conn (accId tracking)
      existingOnBudget `shouldBe` []
      existingTracking `shouldBe` []

    it "listTransactionsInMonth filtert correct op maandgrenzen" $ \conn -> do
      acc <- insertAccount conn "Betaalrekening" Checking >>= expectRight
      _ <- insertInflow conn (accId acc) (fromGregorian 2026 1 31) "Voor" Uncleared (cents 100) Nothing
      inMonth1 <- insertInflow conn (accId acc) (fromGregorian 2026 2 1) "Begin" Uncleared (cents 200) Nothing
      inMonth2 <- insertInflow conn (accId acc) (fromGregorian 2026 2 28) "Eind" Uncleared (cents 300) Nothing
      _ <- insertInflow conn (accId acc) (fromGregorian 2026 3 1) "Na" Uncleared (cents 400) Nothing
      february <- expectRight (mkYearMonth 2026 2)
      results <- listTransactionsInMonth conn february
      map txId results `shouldBe` [txId inMonth1, txId inMonth2]
