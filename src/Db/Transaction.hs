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
  , reconcileAccountIfMatches
  , deleteTransaction
  , updateInflow
  , updateSpending
  , updateTransfer
  ) where

import Control.Exception (Exception, throwIO)
import Control.Monad (forM_)
import Data.List (find)
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
import Domain.Budget (clearedBalance)
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
  , TransactionStatus (Cleared, Reconciled, Uncleared)
  , TransferId (TransferId)
  , YearMonth
  , negateCents
  , nextYearMonth
  , toggleCleared
  , ymMonth
  , ymYear
  , zeroCents
  )

-- $editing
-- 'deleteTransaction' and the @update*@ family both go through
-- 'withReplaceable': an "edit" is implemented as delete-then-reinsert
-- within one SQL transaction, reusing the same raw row-insert helpers
-- ('insertInflowRows'\/'insertSpendingRows'\/'insertTransferRows') a
-- fresh create goes through — never a bespoke @UPDATE@ that would have
-- to re-derive every invariant a create already enforces. The edited
-- transaction gets a *new* 'TransactionId'; nothing in Bucktracker
-- outside of one page render depends on an id staying stable across an
-- edit. Each @update*@ still repeats whatever validation its matching
-- @insert*@ does (on-budget-only, distinct accounts, matching budget
-- status) *before* calling 'withReplaceable' — the raw helpers
-- themselves do no validation, so skipping that step would let an
-- edit create a row a create never could.

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
-- same smart constructor as in Phase 1. No validation of its own (an
-- inflow has nothing an insert currently rejects — account existence is
-- checked at the Api layer), so this doubles as the raw helper behind
-- both a fresh insert and 'updateInflow' (see "$editing").
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
    else Right <$> withTransaction conn (insertSpendingRows conn accId day payee status lines' importHash)

-- | No validation of its own — the raw helper behind both
-- 'insertSpending' and 'updateSpending' (see "$editing"). Must already
-- be running inside a 'withTransaction': inserting the parent row and
-- every line is two-or-more statements that should never be left
-- half-done.
insertSpendingRows
  :: Connection
  -> AccountId
  -> Day
  -> Text
  -> TransactionStatus
  -> NonEmpty TransactionLine
  -> Maybe ImportHash
  -> IO Transaction
insertSpendingRows conn accId day payee status lines' importHash = do
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
-- @mkTransferPair@); (2) the amount must be strictly positive
-- (AUDIT-08, defense in depth beneath 'Api.Money.parsePositiveEuros');
-- (3) they must have the same budget status ('sameBudgetStatus') — the
-- rule newly enforced in Phase 2 from DECISIONS.md §3/§7. Both legs are
-- inserted in one transaction, both starting at @status@ (a freshly
-- created transfer has no prior, independent leg statuses to preserve
-- — contrast 'updateTransfer').
insertTransfer
  :: Connection
  -> (AccountId, AccountId) -- ^ (from, to)
  -> Day
  -> TransactionStatus
  -> Cents -- ^ the transferred amount, as a positive value
  -> IO (Either DomainError (Transaction, Transaction))
insertTransfer conn (fromAccId, toAccId) day status amount
  | fromAccId == toAccId = pure (Left TransferRequiresDistinctAccounts)
  | amount <= zeroCents = pure (Left TransferAmountMustBePositive)
  | otherwise = do
      fromAcc <- requireAccount conn fromAccId
      toAcc <- requireAccount conn toAccId
      if not (sameBudgetStatus fromAcc toAcc)
        then pure (Left TransferRequiresMatchingBudgetStatus)
        else Right <$> withTransaction conn (insertTransferRows conn (fromAccId, toAccId) day (status, status) amount)

-- | No validation of its own — the raw helper behind both
-- 'insertTransfer' and 'updateTransfer' (see "$editing"). Must already
-- be running inside a 'withTransaction': the two legs and the shared
-- @transfers@ row are three statements that should never be left
-- half-done. Takes the "from" and "to" legs' statuses *separately*
-- (AUDIT-02): a fresh 'insertTransfer' passes the same status for both,
-- but 'updateTransfer' must be able to preserve each existing leg's own
-- independent status instead of clobbering one with the other's.
insertTransferRows
  :: Connection
  -> (AccountId, AccountId)
  -> Day
  -> (TransactionStatus, TransactionStatus)
  -> Cents
  -> IO (Transaction, Transaction)
insertTransferRows conn (fromAccId, toAccId) day (fromStatus, toStatus) amount =
  insertBothLegs conn fromAccId toAccId day fromStatus toStatus amount

newtype UnknownAccount = UnknownAccount AccountId deriving stock (Show)
instance Exception UnknownAccount

requireAccount :: Connection -> AccountId -> IO Account
requireAccount conn aid = do
  maybeAcc <- getAccount conn aid
  maybe (throwIO (UnknownAccount aid)) pure maybeAcc

insertBothLegs
  :: Connection
  -> AccountId
  -> AccountId
  -> Day
  -> TransactionStatus
  -> TransactionStatus
  -> Cents
  -> IO (Transaction, Transaction)
insertBothLegs conn fromAccId toAccId day fromStatus toStatus amount = do
  transferId <- allocateTransferId conn
  fromTxId <- insertTransferLeg conn transferId fromAccId day fromStatus (negateCents amount) toAccId
  toTxId <- insertTransferLeg conn transferId toAccId day toStatus amount fromAccId
  pure
    ( Transaction fromTxId fromAccId day "Transfer" fromStatus (TransferLeg transferId toAccId (negateCents amount)) Nothing
    , Transaction toTxId toAccId day "Transfer" toStatus (TransferLeg transferId fromAccId amount) Nothing
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

-- | Reconciliation's "commit" step, made atomic (AUDIT-05): computes
-- 'Domain.Budget.clearedBalance' and compares it against
-- @statementBalance@, and only on a match runs the write — both inside
-- one SQL transaction, on one connection, so no concurrently-cleared
-- row can slip in between the read and the write the way it could when
-- the read ('Domain.Budget.clearedBalance' over a separately-fetched
-- transaction list) and the write ('reconcileAccount') were two
-- separate pool checkouts, as in the original
-- 'Api.Accounts.reconcileAccountHandler'. 'Left' carries the actual
-- cleared balance back, for the "doesn't match" message; 'Right ()'
-- means the write happened.
reconcileAccountIfMatches :: Connection -> AccountId -> Cents -> IO (Either Cents ())
reconcileAccountIfMatches conn aid statementBalance = withTransaction conn $ do
  txs <- listTransactionsForAccount conn aid
  let cleared = clearedBalance aid txs
  if cleared == statementBalance
    then do
      execute conn "UPDATE transactions SET status = ? WHERE account_id = ? AND status = ?" (Reconciled, aid, Cleared)
      pure (Right ())
    else pure (Left cleared)

-- | Deletes a transaction's row(s): both legs sharing a @transfer_id@
-- plus the shared @transfers@ row for a transfer, otherwise just the
-- one row (its @transaction_lines@, if any, cascade via the foreign
-- key). Blocks on an already-'Reconciled' transaction, or one whose
-- transfer sibling leg is already 'Reconciled' (AUDIT-02) — either way
-- 'CannotModifyReconciledTransaction': reconciling a transfer is meant
-- to lock *both* legs, since deleting one leg always deletes the other
-- too. A no-op on an unknown id, consistent with 'setTransactionCleared'.
deleteTransaction :: Connection -> TransactionId -> IO (Either DomainError ())
deleteTransaction conn txId' = do
  result <- withReplaceable conn txId' noKindCheck (\tx _siblings conn' -> Right <$> deleteRowsFor conn' tx)
  pure (() <$ result)

-- | A no-op 'precheck' for 'withReplaceable': 'deleteTransaction' is the
-- one caller that doesn't care what kind of transaction it's deleting.
noKindCheck :: Transaction -> [Transaction] -> Either DomainError ()
noKindCheck _ _ = Right ()

-- | Deletes whatever row(s) back a transaction, without the
-- 'Reconciled' guard or any surrounding transaction — a raw helper
-- shared by 'deleteTransaction' and every @update*@ (via
-- 'withReplaceable').
deleteRowsFor :: Connection -> Transaction -> IO ()
deleteRowsFor conn tx = case txCategorization tx of
  TransferLeg transferId _ _ -> do
    execute conn "DELETE FROM transactions WHERE transfer_id = ?" (Only transferId)
    execute conn "DELETE FROM transfers WHERE id = ?" (Only transferId)
  _ -> execute conn "DELETE FROM transactions WHERE id = ?" (Only (txId tx))

-- | For a 'TransferLeg', every *other* row still sharing the same
-- 'TransferId' (there's exactly one: the other leg) — fetched before
-- any row is ever deleted, so 'withReplaceable''s callers can check or
-- preserve that sibling leg's own state (AUDIT-02: its 'Reconciled'
-- lock status; 'updateTransfer': its independent 'TransactionStatus').
-- Always @[]@ for 'Inflow'\/'Categorized'.
transferSiblingsOf :: Connection -> Transaction -> IO [Transaction]
transferSiblingsOf conn tx = case txCategorization tx of
  TransferLeg transferId _ _ -> do
    rows <-
      query
        conn
        "SELECT id, account_id, date, payee, status, kind, amount, transfer_id, counterpart_account_id, import_hash \
        \FROM transactions WHERE transfer_id = ? AND id != ?"
        (transferId, txId tx)
    traverse (rowToTransaction conn) rows
  _ -> pure []

-- | Blocks on an already-'Reconciled' transaction, or one whose
-- transfer sibling leg is already 'Reconciled' (AUDIT-02): without the
-- second half of this check, deleting or editing the *not-yet-cleared*
-- leg of a part-reconciled transfer would silently delete its
-- 'Reconciled' counterpart leg too (@deleteRowsFor@ always removes both
-- legs together), corrupting the other account's already-confirmed
-- balance.
lockCheck :: Transaction -> [Transaction] -> Either DomainError ()
lockCheck tx siblings
  | txStatus tx == Reconciled || any ((== Reconciled) . txStatus) siblings = Left CannotModifyReconciledTransaction
  | otherwise = Right ()

-- | The shared guard+atomicity behind every "edit" (see "$editing") and
-- 'deleteTransaction': inside one SQL transaction — look up the
-- transaction (closing the read-before-transaction TOCTOU in AUDIT-05,
-- where two concurrent double-click requests could otherwise both see
-- "not yet deleted" and each insert their own replacement, duplicating
-- the edit), block with 'lockCheck' (AUDIT-02), run @precheck@ (e.g.
-- "is this actually the kind of transaction this edit expects",
-- AUDIT-03.2) *before* touching any row, and only once both pass delete
-- the old row(s) and run @replaceWith@. 'Nothing' means the id doesn't
-- exist: a no-op, not an error.
withReplaceable
  :: Connection
  -> TransactionId
  -> (Transaction -> [Transaction] -> Either DomainError ())
  -> (Transaction -> [Transaction] -> Connection -> IO (Either DomainError a))
  -> IO (Either DomainError (Maybe a))
withReplaceable conn txId' precheck replaceWith = withTransaction conn $ do
  maybeTx <- getTransaction conn txId'
  case maybeTx of
    Nothing -> pure (Right Nothing)
    Just tx -> do
      siblings <- transferSiblingsOf conn tx
      case lockCheck tx siblings >> precheck tx siblings of
        Left err -> pure (Left err)
        Right () -> do
          deleteRowsFor conn tx
          result <- replaceWith tx siblings conn
          pure (fmap Just result)

-- | AUDIT-03.1: an edit that keeps the transaction on the *same*
-- account preserves its 'txImportHash' (so Track C's bank-statement
-- import still recognizes this row and doesn't re-import a duplicate);
-- moving it to a different account drops the hash, since it's then no
-- longer standing in for that one imported row.
preservedImportHash :: AccountId -> Transaction -> Maybe ImportHash
preservedImportHash newAccId tx
  | newAccId == txAccount tx = txImportHash tx
  | otherwise = Nothing

-- | AUDIT-03.2 'precheck's: reject an edit whose target id doesn't
-- actually hold the kind of transaction that edit form expects (e.g.
-- posting to @edit-inflow@ for an id that's really a split or a
-- transfer leg) — without this, 'withReplaceable' would delete whatever
-- that row actually was (both legs, for a transfer!) and silently
-- replace it with the wrong kind.
expectInflow, expectCategorized, expectTransferLeg :: Transaction -> [Transaction] -> Either DomainError ()
expectInflow tx _ = case txCategorization tx of
  Inflow _ -> Right ()
  _        -> Left TransactionKindMismatch
expectCategorized tx _ = case txCategorization tx of
  Categorized _ -> Right ()
  _             -> Left TransactionKindMismatch
expectTransferLeg tx _ = case txCategorization tx of
  TransferLeg {} -> Right ()
  _              -> Left TransactionKindMismatch

-- | Edits an inflow's date/payee/account/amount in place (same shape,
-- new 'TransactionId' — see "$editing"). No validation of its own
-- beyond 'expectInflow', matching 'insertInflow'.
updateInflow
  :: Connection -> TransactionId -> AccountId -> Day -> Text -> Cents -> IO (Either DomainError (Maybe Transaction))
updateInflow conn txId' accId day payee amount =
  withReplaceable conn txId' expectInflow $ \tx _siblings conn' ->
    Right <$> insertInflow conn' accId day payee (txStatus tx) amount (preservedImportHash accId tx)

-- | Edits a split transaction's date/payee/account/lines in place (same
-- shape, new 'TransactionId'). Repeats 'insertSpending's own
-- on-budget-only validation before touching anything, since the raw
-- row helper it reuses underneath does not.
updateSpending
  :: Connection
  -> TransactionId
  -> AccountId
  -> Day
  -> Text
  -> NonEmpty TransactionLine
  -> IO (Either DomainError (Maybe Transaction))
updateSpending conn txId' accId day payee lines' = do
  acc <- requireAccount conn accId
  if not (isOnBudget acc)
    then pure (Left CategorizedTransactionRequiresOnBudgetAccount)
    else withReplaceable conn txId' expectCategorized $ \tx _siblings conn' ->
           Right <$> insertSpendingRows conn' accId day payee (txStatus tx) lines' (preservedImportHash accId tx)

-- | Edits a transfer's date/amount/both accounts in place — both legs
-- and the @transfers@ row are replaced together (there's no single
-- "the" leg being edited; editing either side's form edits the whole
-- pair). Repeats 'insertTransfer's own distinct-accounts/positive-
-- amount/matching-budget-status validation before touching anything.
-- Preserves each side's own prior 'TransactionStatus' individually
-- (AUDIT-02) by matching the new "from"/"to" accounts back to whichever
-- old leg (if any) was already on that account — a newly swapped-in
-- account (the transfer's accounts changed, not just its amount/date)
-- starts that side fresh at 'Uncleared', same as a brand new transfer.
updateTransfer
  :: Connection
  -> TransactionId
  -> (AccountId, AccountId)
  -> Day
  -> Cents
  -> IO (Either DomainError (Maybe (Transaction, Transaction)))
updateTransfer conn txId' (fromAccId, toAccId) day amount
  | fromAccId == toAccId = pure (Left TransferRequiresDistinctAccounts)
  | amount <= zeroCents = pure (Left TransferAmountMustBePositive)
  | otherwise = do
      fromAcc <- requireAccount conn fromAccId
      toAcc <- requireAccount conn toAccId
      if not (sameBudgetStatus fromAcc toAcc)
        then pure (Left TransferRequiresMatchingBudgetStatus)
        else withReplaceable conn txId' expectTransferLeg $ \tx siblings conn' ->
               let oldLegs = tx : siblings
                   statusForAccount aid = maybe Uncleared txStatus (find ((== aid) . txAccount) oldLegs)
               in Right
                    <$> insertTransferRows
                          conn'
                          (fromAccId, toAccId)
                          day
                          (statusForAccount fromAccId, statusForAccount toAccId)
                          amount
