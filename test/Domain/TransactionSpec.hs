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
  describe "mkTransferPair (invariant 2: een transfer sommeert naar 0)" $ do
    it "wijst een transfer naar dezelfde rekening af" $
      property $ \acc day status amount ->
        mkTransferPair (TransferId 1) (TransactionId 1, acc) (TransactionId 2, acc) day status amount
          === Left TransferRequiresDistinctAccounts

    it "de twee legs sommeren altijd naar zeroCents" $
      property $ \fromAcc toAcc day status amount ->
        fromAcc /= toAcc ==>
          case mkTransferPair (TransferId 1) (TransactionId 1, fromAcc) (TransactionId 2, toAcc)
                 day status amount of
            Right (legFrom, legTo) ->
              transactionAmount legFrom <> transactionAmount legTo == zeroCents
            Left _ -> False

    it "de verliezende kant is exact de negatie van het overgemaakte bedrag" $
      property $ \fromAcc toAcc day status amount ->
        fromAcc /= toAcc ==>
          case mkTransferPair (TransferId 1) (TransactionId 1, fromAcc) (TransactionId 2, toAcc)
                 day status amount of
            Right (legFrom, legTo) ->
              transactionAmount legFrom == negateCents amount && transactionAmount legTo == amount
            Left _ -> False

  describe "mkSpendingTransaction (invariant 3: splits sommeren naar het totaal)" $ do
    it "transactionAmount is altijd de som van de regels" $
      property $ \tid acc day status headLine tailLines ->
        let linesNE = headLine :| tailLines
            tx = mkSpendingTransaction tid acc day "Test" status linesNE Nothing
        in transactionAmount tx == mconcat (tlAmount <$> toList linesNE)

    it "een split gebouwd via splitEvenly sommeert naar het oorspronkelijke bedrag" $
      property $ \tid acc day status cat amount n ->
        let count = max 1 n
            headCents :| tailCents = splitEvenly amount count
            linesNE = TransactionLine cat headCents :| map (TransactionLine cat) tailCents
            tx = mkSpendingTransaction tid acc day "Test" status linesNE Nothing
        in transactionAmount tx == amount

-- Invariant 5 ("geen transactie zonder rekening; precies één categorie of
-- split") is hier typeniveau: 'txAccount' is een verplicht veld en
-- 'Categorized' gebruikt 'NonEmpty', dus er is geen losse property voor
-- nodig. Zie 'Domain.BudgetSpec' voor hoe dat zich vertaalt naar
-- rekeningsaldi.
