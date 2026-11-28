module Domain.TransactionSpec (spec) where

import Data.List.NonEmpty (NonEmpty (..), toList)
import Domain.Error (DomainError (..))
import Domain.Gen ()
import Domain.Transaction
import Domain.Types
import Test.Hspec
import Test.QuickCheck

spec :: Spec
spec = do
  describe "mkTransferPair (invariant 2: a transfer sums to 0)" $ do
    it "rejects a transfer to the same account" $
      property $ \acc day status amount ->
        amount > zeroCents ==>
          mkTransferPair (TransferId 1) (TransactionId 1, acc) (TransactionId 2, acc) day status amount
            === Left TransferRequiresDistinctAccounts

    it "rejects a zero or negative amount, even between two different accounts (AUDIT-08)" $
      property $ \fromAcc toAcc day status amount ->
        fromAcc /= toAcc && amount <= zeroCents ==>
          mkTransferPair (TransferId 1) (TransactionId 1, fromAcc) (TransactionId 2, toAcc) day status amount
            === Left TransferAmountMustBePositive

    it "the two legs always sum to zeroCents" $
      property $ \fromAcc toAcc day status amount ->
        fromAcc /= toAcc && amount > zeroCents ==>
          case mkTransferPair (TransferId 1) (TransactionId 1, fromAcc) (TransactionId 2, toAcc)
                 day status amount of
            Right (legFrom, legTo) ->
              transactionAmount legFrom <> transactionAmount legTo == zeroCents
            Left _ -> False

    it "the losing side is exactly the negation of the transferred amount" $
      property $ \fromAcc toAcc day status amount ->
        fromAcc /= toAcc && amount > zeroCents ==>
          case mkTransferPair (TransferId 1) (TransactionId 1, fromAcc) (TransactionId 2, toAcc)
                 day status amount of
            Right (legFrom, legTo) ->
              transactionAmount legFrom == negateCents amount && transactionAmount legTo == amount
            Left _ -> False

  describe "mkSpendingTransaction (invariant 3: splits sum to the total)" $ do
    it "transactionAmount is always the sum of the lines" $
      property $ \tid acc day status headLine tailLines ->
        let linesNE = headLine :| tailLines
            tx = mkSpendingTransaction tid acc day "Test" status linesNE Nothing
        in transactionAmount tx == mconcat (tlAmount <$> toList linesNE)

    it "a split built via splitEvenly sums to the original amount" $
      property $ \tid acc day status cat amount n ->
        let count = max 1 n
            headCents :| tailCents = splitEvenly amount count
            linesNE = TransactionLine cat headCents :| map (TransactionLine cat) tailCents
            tx = mkSpendingTransaction tid acc day "Test" status linesNE Nothing
        in transactionAmount tx == amount

-- Invariant 5 ("no transaction without an account; exactly one category
-- or a split") is type-level here: 'txAccount' is a required field and
-- 'Categorized' uses 'NonEmpty', so no separate property is needed for
-- it. See 'Domain.BudgetSpec' for how that translates to account
-- balances.
