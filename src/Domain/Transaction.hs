module Domain.Transaction
  ( TransactionLine (..)
  , Categorization (..)
  , Transaction (..)
  , transactionAmount
  , mkInflowTransaction
  , mkSpendingTransaction
  , mkTransferPair
  ) where

import Data.List.NonEmpty (NonEmpty, toList)
import Data.Text (Text)
import Data.Time (Day)
import Domain.Error (DomainError (..))
import Domain.Types
  ( AccountId
  , Cents
  , CategoryId
  , ImportHash
  , TransactionId
  , TransactionStatus
  , TransferId
  , negateCents
  )

-- | One line of an (optionally split) transaction.
data TransactionLine = TransactionLine
  { tlCategory :: CategoryId
  , tlAmount   :: Cents
  } deriving stock (Eq, Show)

-- | Where a transaction's amount goes. A closed sum type: a transaction
-- is always exactly one of the three, never "none of them" or "both" —
-- that makes invariant 5 ("every non-transfer transaction has a
-- category, or is a split") a type-level guarantee for the
-- 'Categorized' branch.
data Categorization
  = -- | A normal expense/income, split across one or more categories.
    -- 'NonEmpty' guarantees at least one line: "a split with no lines"
    -- is unrepresentable.
    Categorized (NonEmpty TransactionLine)
  | -- | Flows straight into Ready to Assign (income, opening balance).
    -- Deliberately has no category: this money *is* what still needs to
    -- be allocated. See DECISIONS.md §3 for why this is a deliberate
    -- exception rather than a gap in the invariant.
    Inflow Cents
  | -- | The other side of a transfer; touches no category and no Ready
    -- to Assign. Carries the opposite 'AccountId' and the (already
    -- signed) amount for *this* side of the transfer.
    TransferLeg TransferId AccountId Cents
  deriving stock (Eq, Show)

data Transaction = Transaction
  { txId             :: TransactionId
  , txAccount        :: AccountId
  , txDate           :: Day
  , txPayee          :: Text
  , txStatus         :: TransactionStatus
  , txCategorization :: Categorization
  , txImportHash     :: Maybe ImportHash
  } deriving stock (Eq, Show)

-- | The total, signed effect of this transaction on the account
-- balance. For 'Categorized' this is, by definition, the sum of the
-- lines — a split can therefore never drift from the total (invariant
-- 3), because there's no separate total for it to drift from.
transactionAmount :: Transaction -> Cents
transactionAmount tx = case txCategorization tx of
  Categorized ls         -> mconcat (map tlAmount (toList ls))
  Inflow amount          -> amount
  TransferLeg _ _ amount -> amount

mkInflowTransaction
  :: TransactionId
  -> AccountId
  -> Day
  -> Text
  -> TransactionStatus
  -> Cents
  -> Maybe ImportHash
  -> Transaction
mkInflowTransaction tid acc day payee status amount importHash =
  Transaction tid acc day payee status (Inflow amount) importHash

mkSpendingTransaction
  :: TransactionId
  -> AccountId
  -> Day
  -> Text
  -> TransactionStatus
  -> NonEmpty TransactionLine
  -> Maybe ImportHash
  -> Transaction
mkSpendingTransaction tid acc day payee status lines' importHash =
  Transaction tid acc day payee status (Categorized lines') importHash

-- | Build the two linked halves of a transfer. By construction they
-- always sum to zero (invariant 2): one half is literally the negation
-- of the other, so there's no separate validation that could forget to
-- do that. The only failure mode: both sides are the same account.
mkTransferPair
  :: TransferId
  -> (TransactionId, AccountId) -- ^ (id, account) of the side that *loses* the money
  -> (TransactionId, AccountId) -- ^ (id, account) of the side that *receives* the money
  -> Day
  -> TransactionStatus
  -> Cents -- ^ the transferred amount, as a positive value
  -> Either DomainError (Transaction, Transaction)
mkTransferPair tid (fromTxId, fromAcc) (toTxId, toAcc) day status amount
  | fromAcc == toAcc = Left TransferRequiresDistinctAccounts
  | otherwise = Right
      ( Transaction fromTxId fromAcc day "Transfer" status
          (TransferLeg tid toAcc (negateCents amount)) Nothing
      , Transaction toTxId toAcc day "Transfer" status
          (TransferLeg tid fromAcc amount) Nothing
      )
