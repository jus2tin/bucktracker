module Db.Transaction
  ( insertInflow
  , insertSpending
  , insertTransfer
  , getTransaction
  , listTransactionsForAccount
  , listTransactionsInMonth
  , listAllTransactions
  , setTransactionCleared
  , reconcileAccount
  ) where

import Control.Exception (Exception, throwIO)
import Control.Monad (forM_)
import Data.List.NonEmpty (NonEmpty (..), toList)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (Day, fromGregorian, getCurrentTime)
import Database.SQLite.Simple
  ( Connection
  , FromRow (..)
  , Only (Only)
  , execute
  , field
  , lastInsertRowId
  , query
  , query_
  , withTransaction
  )
import Db.Account (getAccount)
import Db.Field ()
import Domain.Account (Account, isOnBudget, sameBudgetStatus)
import Domain.Error (DomainError (..))
import Domain.Transaction
  ( Categorization (Categorized, Inflow, TransferLeg)
  , Transaction (..)
  , TransactionLine (TransactionLine, tlAmount, tlCategory)
  , mkInflowTransaction
  , mkSpendingTransaction
  )
import Domain.Types
  ( AccountId
  , Cents
  , ImportHash
  , TransactionId (TransactionId)
  , TransactionStatus (Cleared, Reconciled)
  , TransferId (TransferId)
  , YearMonth
  , negateCents
  , nextYearMonth
  , toggleCleared
  , ymMonth
  , ymYear
  )

-- | Only thrown if a row has a shape that, given the CHECK constraints
-- in the migrations, should be impossible (e.g. kind = 'inflow' but
-- amount is NULL). Not a silent, wrong default: that would corrupt
-- data; a plain 'error'/'fromJust' would in turn break the
-- total-functions rule. This is the IO equivalent: an explicit, typed,
-- catchable exception.
newtype CorruptRow = CorruptRow Text deriving stock (Show)
instance Exception CorruptRow

requireField :: Text -> Maybe a -> IO a
requireField label = maybe (throwIO (CorruptRow label)) pure

-- Plain row representation of the transactions table, before merging
-- with transaction_lines (for 'Categorized') into a real 'Transaction'.
data TransactionRow = TransactionRow
  { trId          :: TransactionId
  , trAccount     :: AccountId
  , trDate        :: Day
  , trPayee       :: Text
  , trStatus      :: TransactionStatus
  , trKind        :: Text
  , trAmount      :: Maybe Cents
  , trTransferId  :: Maybe TransferId
  , trCounterpart :: Maybe AccountId
  , trImportHash  :: Maybe ImportHash
  }

instance FromRow TransactionRow where
  fromRow =
    TransactionRow
      <$> field <*> field <*> field <*> field <*> field
      <*> field <*> field <*> field <*> field <*> field

instance FromRow TransactionLine where
  fromRow = TransactionLine <$> field <*> field

rowToTransaction :: Connection -> TransactionRow -> IO Transaction
rowToTransaction conn row = do
  categorization <- case trKind row of
    "inflow" -> Inflow <$> requireField "transactions.amount (kind=inflow)" (trAmount row)
    "transfer" ->
      TransferLeg
        <$> requireField "transactions.transfer_id (kind=transfer)" (trTransferId row)
        <*> requireField "transactions.counterpart_account_id (kind=transfer)" (trCounterpart row)
        <*> requireField "transactions.amount (kind=transfer)" (trAmount row)
    _ -> Categorized <$> fetchLines conn (trId row)
  pure
    Transaction
      { txId = trId row
      , txAccount = trAccount row
      , txDate = trDate row
      , txPayee = trPayee row
      , txStatus = trStatus row
      , txCategorization = categorization
      , txImportHash = trImportHash row
      }

fetchLines :: Connection -> TransactionId -> IO (NonEmpty TransactionLine)
fetchLines conn txId' = do
  rows <-
    query
      conn
      "SELECT category_id, amount FROM transaction_lines WHERE transaction_id = ? ORDER BY id"
      (Only txId')
  case rows of
    (x : xs) -> pure (x :| xs)
    [] ->
      throwIO
        (CorruptRow ("transaction_lines has none for kind='categorized' transaction " <> Text.pack (show txId')))

-- | Amount and payee come from 'Domain.Transaction.mkInflowTransaction'
-- — the insert only builds the row, the domain object comes from the
-- same smart constructor as in Phase 1.
insertInflow
  :: Connection
  -> AccountId
  -> Day
  -> Text
  -> TransactionStatus
  -> Cents
  -> Maybe ImportHash
  -> IO Transaction
insertInflow conn accId day payee status amount importHash = do
  execute
    conn
    ( "INSERT INTO transactions (account_id, date, payee, status, kind, amount, transfer_id, counterpart_account_id, import_hash) \
      \VALUES (?, ?, ?, ?, ?, ?, NULL, NULL, ?)"
    )
    (accId, day, payee, status, "inflow" :: Text, amount, importHash)
  txId' <- TransactionId <$> lastInsertRowId conn
  pure (mkInflowTransaction txId' accId day payee status amount importHash)

-- | Rejects a 'Categorized' transaction on a tracking account
-- ('CategorizedTransactionRequiresOnBudgetAccount') before it's ever
-- persisted — this is the enforcement point for invariant 1 that Phase
-- 2 originally left out: a tracking account's balance is excluded from
-- 'Domain.Budget.onBudgetBalanceTotal', so letting categorized spending
-- land there would make money silently appear/disappear in the budget.
-- (See 'Domain.Budget.categoryActivity' for the matching defense-in-depth
-- check on the read side.)
insertSpending
  :: Connection
  -> AccountId
  -> Day
  -> Text
  -> TransactionStatus
  -> NonEmpty TransactionLine
  -> Maybe ImportHash
  -> IO (Either DomainError Transaction)
insertSpending conn accId day payee status lines' importHash = do
  acc <- requireAccount conn accId
  if not (isOnBudget acc)
    then pure (Left CategorizedTransactionRequiresOnBudgetAccount)
    else Right <$> withTransaction conn insertRows
  where
    insertRows = do
      execute
        conn
        ( "INSERT INTO transactions (account_id, date, payee, status, kind, amount, transfer_id, counterpart_account_id, import_hash) \
          \VALUES (?, ?, ?, ?, ?, NULL, NULL, NULL, ?)"
        )
        (accId, day, payee, status, "categorized" :: Text, importHash)
      txId' <- TransactionId <$> lastInsertRowId conn
      forM_ (toList lines') $ \line ->
        execute
          conn
          "INSERT INTO transaction_lines (transaction_id, category_id, amount) VALUES (?, ?, ?)"
          (txId', tlCategory line, tlAmount line)
      pure (mkSpendingTransaction txId' accId day payee status lines' importHash)

-- | The two legs of a transfer. Validates, in this order: (1) the two
-- accounts must differ (same check as Phase 1's pure
-- @mkTransferPair@); (2) they must have the same budget status
-- ('sameBudgetStatus') — the rule newly enforced in Phase 2 from
-- DECISIONS.md §3/§7. Both legs are inserted in one transaction.
insertTransfer
  :: Connection
  -> (AccountId, AccountId) -- ^ (from, to)
  -> Day
  -> TransactionStatus
  -> Cents -- ^ the transferred amount, as a positive value
  -> IO (Either DomainError (Transaction, Transaction))
insertTransfer conn (fromAccId, toAccId) day status amount
  | fromAccId == toAccId = pure (Left TransferRequiresDistinctAccounts)
  | otherwise = do
      fromAcc <- requireAccount conn fromAccId
      toAcc <- requireAccount conn toAccId
      if not (sameBudgetStatus fromAcc toAcc)
        then pure (Left TransferRequiresMatchingBudgetStatus)
        else Right <$> withTransaction conn (insertBothLegs conn fromAccId toAccId day status amount)

newtype UnknownAccount = UnknownAccount AccountId deriving stock (Show)
instance Exception UnknownAccount

requireAccount :: Connection -> AccountId -> IO Account
requireAccount conn aid = do
  maybeAcc <- getAccount conn aid
  maybe (throwIO (UnknownAccount aid)) pure maybeAcc

insertBothLegs
  :: Connection -> AccountId -> AccountId -> Day -> TransactionStatus -> Cents -> IO (Transaction, Transaction)
insertBothLegs conn fromAccId toAccId day status amount = do
  transferId <- allocateTransferId conn
  fromTxId <- insertTransferLeg conn transferId fromAccId day status (negateCents amount) toAccId
  toTxId <- insertTransferLeg conn transferId toAccId day status amount fromAccId
  pure
    ( Transaction fromTxId fromAccId day "Transfer" status (TransferLeg transferId toAccId (negateCents amount)) Nothing
    , Transaction toTxId toAccId day "Transfer" status (TransferLeg transferId fromAccId amount) Nothing
    )

allocateTransferId :: Connection -> IO TransferId
allocateTransferId conn = do
  now <- getCurrentTime
  execute conn "INSERT INTO transfers (created_at) VALUES (?)" (Only now)
  TransferId <$> lastInsertRowId conn

insertTransferLeg
  :: Connection -> TransferId -> AccountId -> Day -> TransactionStatus -> Cents -> AccountId -> IO TransactionId
insertTransferLeg conn transferId accId day status amount counterpartId = do
  execute
    conn
    ( "INSERT INTO transactions (account_id, date, payee, status, kind, amount, transfer_id, counterpart_account_id, import_hash) \
      \VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL)"
    )
    (accId, day, "Transfer" :: Text, status, "transfer" :: Text, amount, transferId, counterpartId)
  TransactionId <$> lastInsertRowId conn

-- The column list is deliberately spelled out literally three times
-- instead of assembled via a shared helper: 'Query' does have an
-- 'IsString' instance for plain literals, but concatenating a
-- separately-built 'Text' value with that is needless risk for three
-- simple, fixed SELECTs.
getTransaction :: Connection -> TransactionId -> IO (Maybe Transaction)
getTransaction conn txId' = do
  rows <-
    query
      conn
      "SELECT id, account_id, date, payee, status, kind, amount, transfer_id, counterpart_account_id, import_hash \
      \FROM transactions WHERE id = ?"
      (Only txId')
  case rows of
    [row] -> Just <$> rowToTransaction conn row
    _ -> pure Nothing

listTransactionsForAccount :: Connection -> AccountId -> IO [Transaction]
listTransactionsForAccount conn accId = do
  rows <-
    query
      conn
      "SELECT id, account_id, date, payee, status, kind, amount, transfer_id, counterpart_account_id, import_hash \
      \FROM transactions WHERE account_id = ? ORDER BY date, id"
      (Only accId)
  traverse (rowToTransaction conn) rows

-- | All transactions dated within the given calendar month. Needed to
-- feed 'Domain.Budget.categoryActivity'/'accountInflows' (the Db layer
-- delivers rows, the actual rollover calculation stays in Domain.Budget
-- — see CLAUDE.md "Architecture").
listTransactionsInMonth :: Connection -> YearMonth -> IO [Transaction]
listTransactionsInMonth conn ym = do
  rows <-
    query
      conn
      "SELECT id, account_id, date, payee, status, kind, amount, transfer_id, counterpart_account_id, import_hash \
      \FROM transactions WHERE date >= ? AND date < ? ORDER BY date, id"
      (firstDay, firstDayNextMonth)
  traverse (rowToTransaction conn) rows
  where
    firstDay = fromGregorian (fromIntegral (ymYear ym)) (ymMonth ym) 1
    nextYm = nextYearMonth ym
    firstDayNextMonth = fromGregorian (fromIntegral (ymYear nextYm)) (ymMonth nextYm) 1

-- | Every transaction ever recorded, across all accounts and months —
-- unlike 'listTransactionsInMonth', deliberately not restricted to one
-- month. Needed to fold the multi-month rollover
-- ('Domain.Budget.rolloverMonths') from the first month with any
-- activity up through the current one (DECISIONS.md §8, H-5).
listAllTransactions :: Connection -> IO [Transaction]
listAllTransactions conn = do
  rows <-
    query_
      conn
      "SELECT id, account_id, date, payee, status, kind, amount, transfer_id, counterpart_account_id, import_hash \
      \FROM transactions ORDER BY date, id"
  traverse (rowToTransaction conn) rows

-- | Flips a transaction between 'Domain.Types.Uncleared' and
-- 'Domain.Types.Cleared' from the register ('Domain.Types.toggleCleared').
-- A no-op on an unknown id or an already-'Reconciled' transaction —
-- reconciling is the deliberate, account-wide action in
-- 'reconcileAccount', not something a single click on one row should
-- be able to undo.
setTransactionCleared :: Connection -> TransactionId -> IO ()
setTransactionCleared conn txId' = withTransaction conn $ do
  rows <- query conn "SELECT status FROM transactions WHERE id = ?" (Only txId') :: IO [Only TransactionStatus]
  case rows of
    [Only current] ->
      execute conn "UPDATE transactions SET status = ? WHERE id = ?" (toggleCleared current, txId')
    _ -> pure ()

-- | The "commit" step of reconciling an account: every 'Cleared'
-- transaction on it becomes 'Reconciled'. Only ever called once the
-- caller has already confirmed 'Domain.Budget.clearedBalance' matches
-- the bank statement ('Api.Accounts') — this function itself doesn't
-- check that; it's just the write.
reconcileAccount :: Connection -> AccountId -> IO ()
reconcileAccount conn aid =
  execute
    conn
    "UPDATE transactions SET status = ? WHERE account_id = ? AND status = ?"
    (Reconciled, aid, Cleared)
