-- | Shared 'Arbitrary' instances and generators for the Domain tests.
--
-- Not production code (orphan instances are deliberate here, as is
-- customary in test suites), but still total: generators that could
-- "fail" (e.g. a smart constructor returning an 'Either') simply retry
-- instead of crashing — they're always called with valid input, so that
-- path is unreachable but never unsafe.
module Domain.Gen
  ( genCents
  , genYearMonth
  , genDayIn
  , genAccount
  , genCategory
  , World (..)
  , genWorld
  , MultiMonthWorld (..)
  , genMultiMonthWorld
  ) where

import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.Text as Text
import Data.Time (Day, fromGregorian)
import Domain.Account (Account, accId, mkAccount)
import Domain.Budget (Assignment (..), CategoryMonth (..))
import Domain.Category (Category, catId, mkCategory)
import Domain.Transaction
  ( Categorization (..)
  , Transaction (..)
  , TransactionLine (..)
  , mkInflowTransaction
  , mkSpendingTransaction
  , mkTransferPair
  )
import Domain.Types
import Test.QuickCheck

-- * Basic types

-- | Bounded to +/- 1,000,000.00 EUR so sums over lists of reasonable
-- length never approach the limits of 'Data.Int.Int64'.
genCents :: Gen Cents
genCents = cents <$> choose (-100000000, 100000000)

instance Arbitrary Cents where
  arbitrary = genCents

instance Arbitrary AccountType where
  arbitrary = elements [minBound .. maxBound]

instance Arbitrary TransactionStatus where
  arbitrary = elements [minBound .. maxBound]

genYearMonth :: Gen YearMonth
genYearMonth = do
  y <- choose (2000, 2100)
  m <- choose (1, 12)
  case mkYearMonth y m of
    Right ym -> pure ym
    Left _   -> genYearMonth -- unreachable: m is already in [1,12]

instance Arbitrary YearMonth where
  arbitrary = genYearMonth

genDayIn :: YearMonth -> Gen Day
genDayIn ym = do
  d <- choose (1, 28) -- 28: valid in every month, no calendar arithmetic needed
  pure (fromGregorian (fromIntegral (ymYear ym)) (ymMonth ym) d)

instance Arbitrary Day where
  arbitrary = genYearMonth >>= genDayIn

-- Small, deliberately overlapping ranges: this way, equality between
-- two independently generated IDs regularly comes out both True and
-- False, which is needed to properly test filtering logic (e.g. "only
-- lines for *this* category").
instance Arbitrary AccountId where
  arbitrary = AccountId <$> choose (1, 20)

instance Arbitrary CategoryGroupId where
  arbitrary = CategoryGroupId <$> choose (1, 20)

instance Arbitrary CategoryId where
  arbitrary = CategoryId <$> choose (1, 20)

instance Arbitrary TransactionId where
  arbitrary = TransactionId <$> choose (1, 1000)

instance Arbitrary TransferId where
  arbitrary = TransferId <$> choose (1, 1000)

instance Arbitrary TransactionLine where
  arbitrary = TransactionLine <$> arbitrary <*> arbitrary

instance Arbitrary Categorization where
  arbitrary =
    oneof
      [ Categorized <$> ((:|) <$> arbitrary <*> arbitrary)
      , Inflow <$> arbitrary
      , TransferLeg <$> arbitrary <*> arbitrary <*> arbitrary
      ]

-- | Standalone transactions on their own (no world with matching
-- accounts/categories around them) — useful for structural properties
-- such as "a transaction only ever touches its own account".
instance Arbitrary Transaction where
  arbitrary =
    Transaction
      <$> arbitrary
      <*> arbitrary
      <*> arbitrary
      <*> pure "Payee"
      <*> arbitrary
      <*> arbitrary
      <*> pure Nothing

instance Arbitrary CategoryMonth where
  arbitrary = CategoryMonth <$> arbitrary <*> arbitrary <*> arbitrary <*> arbitrary <*> arbitrary

-- * Entities via the real smart constructors

genAccount :: Int -> AccountType -> Gen Account
genAccount n ty =
  case mkAccount (AccountId (fromIntegral n)) (Text.pack ("Account " ++ show n)) ty of
    Right acc -> pure acc
    Left _    -> genAccount n ty -- unreachable: the name is never empty

genCategory :: Int -> CategoryGroupId -> Gen Category
genCategory n gid =
  case mkCategory (CategoryId (fromIntegral n)) gid (Text.pack ("Category " ++ show n)) of
    Right cat -> pure cat
    Left _    -> genCategory n gid -- unreachable: the name is never empty

genLine :: [Category] -> Gen TransactionLine
genLine categories = do
  cat <- elements categories
  amt <- genCents
  pure (TransactionLine (catId cat) amt)

genCategorizedTx :: YearMonth -> [Account] -> [Category] -> Gen Transaction
genCategorizedTx month onBudgetAccs categories = do
  acc <- elements onBudgetAccs
  day <- genDayIn month
  status <- arbitrary
  firstLine <- genLine categories
  extraCount <- choose (0, 2)
  extraLines <- vectorOf extraCount (genLine categories)
  pure (mkSpendingTransaction (TransactionId 0) (accId acc) day "Groceries" status
          (firstLine :| extraLines) Nothing)

genInflowTx :: YearMonth -> [Account] -> Gen Transaction
genInflowTx month accounts = do
  acc <- elements accounts
  day <- genDayIn month
  status <- arbitrary
  amt <- genCents
  pure (mkInflowTransaction (TransactionId 0) (accId acc) day "Income" status amt Nothing)

genDistinctPair :: [Account] -> Gen (Account, Account)
genDistinctPair accs = do
  a <- elements accs
  b <- elements accs
  if accId a == accId b then genDistinctPair accs else pure (a, b)

-- | Both legs of a transfer, always between two *different* on-budget
-- accounts (see DECISIONS.md §3 for why a mixed on-budget/tracking
-- transfer is deliberately not generated here) and a strictly positive
-- amount (AUDIT-08: 'mkTransferPair' rejects zero/negative amounts).
genTransferTxs :: YearMonth -> [Account] -> Gen [Transaction]
genTransferTxs month onBudgetAccs = do
  (fromAcc, toAcc) <- genDistinctPair onBudgetAccs
  day <- genDayIn month
  status <- arbitrary
  amt <- cents <$> choose (1, 100000000)
  case mkTransferPair (TransferId 0) (TransactionId 0, accId fromAcc) (TransactionId 0, accId toAcc)
         day status amt of
    Right (legA, legB) -> pure [legA, legB]
    Left _             -> pure [] -- unreachable: fromAcc /= toAcc and amt > 0 are both guaranteed

genAssignmentFor :: YearMonth -> Category -> Gen Assignment
genAssignmentFor month cat = Assignment (catId cat) month <$> genCents

-- * A complete, internally consistent ledger

-- | A "world": accounts, categories, assignments and transactions that
-- are internally consistent (every category/account referenced by a
-- transaction or assignment actually exists) — needed to meaningfully
-- test the ledger-wide invariant (invariant 1). See
-- 'Domain.Budget.budgetBalancesAccounts'.
data World = World
  { wAccounts     :: [Account]
  , wCategories   :: [Category]
  , wMonth        :: YearMonth
  , wAssignments  :: [Assignment]
  , wTransactions :: [Transaction]
  } deriving stock (Show)

genWorld :: Gen World
genWorld = do
  month <- genYearMonth

  nOnBudget <- choose (1, 3)
  nTracking <- choose (0, 2)
  onBudgetTypes <- vectorOf nOnBudget (elements [Checking, Savings, Cash])
  onBudgetAccs <- sequence (zipWith genAccount [1 ..] onBudgetTypes)
  trackingAccs <- traverse (`genAccount` Tracking) [nOnBudget + 1 .. nOnBudget + nTracking]
  let accounts = onBudgetAccs ++ trackingAccs

  nCategories <- choose (1, 4)
  let groupId = CategoryGroupId 1
  categories <- traverse (`genCategory` groupId) [1 .. nCategories]

  assignments <- traverse (genAssignmentFor month) categories

  nCategorized <- choose (0, 5)
  categorizedTxs <- vectorOf nCategorized (genCategorizedTx month onBudgetAccs categories)

  nInflows <- choose (0, 4)
  inflowTxs <- vectorOf nInflows (genInflowTx month accounts)

  transferTxs <-
    if length onBudgetAccs >= 2
      then do
        nTransfers <- choose (0, 3)
        concat <$> vectorOf nTransfers (genTransferTxs month onBudgetAccs)
      else pure []

  let rawTxs = categorizedTxs ++ inflowTxs ++ transferTxs
      numberedTxs = zipWith (\i tx -> tx { txId = TransactionId i }) [1 ..] rawTxs

  pure World
    { wAccounts = accounts
    , wCategories = categories
    , wMonth = month
    , wAssignments = assignments
    , wTransactions = numberedTxs
    }

-- * A ledger spanning several consecutive months

-- | Like 'World', but spanning several *consecutive* months with the
-- same accounts/categories throughout — needed to test the multi-month
-- rollover orchestrator ('Domain.Budget.rolloverMonths', DECISIONS.md
-- §8 H-5), which folds carry/Ready-to-Assign from one month into the
-- next.
data MultiMonthWorld = MultiMonthWorld
  { mmwAccounts     :: [Account]
  , mmwCategories   :: [Category]
  , mmwMonths       :: [YearMonth] -- ^ non-empty, consecutive, ascending
  , mmwAssignments  :: [Assignment]
  , mmwTransactions :: [Transaction]
  } deriving stock (Show)

genMultiMonthWorld :: Gen MultiMonthWorld
genMultiMonthWorld = do
  startMonth <- genYearMonth
  nMonths <- choose (2, 4)
  let months = take nMonths (iterate nextYearMonth startMonth)

  nOnBudget <- choose (1, 3)
  nTracking <- choose (0, 2)
  onBudgetTypes <- vectorOf nOnBudget (elements [Checking, Savings, Cash])
  onBudgetAccs <- sequence (zipWith genAccount [1 ..] onBudgetTypes)
  trackingAccs <- traverse (`genAccount` Tracking) [nOnBudget + 1 .. nOnBudget + nTracking]
  let accounts = onBudgetAccs ++ trackingAccs

  nCategories <- choose (1, 4)
  let groupId = CategoryGroupId 1
  categories <- traverse (`genCategory` groupId) [1 .. nCategories]

  perMonth <- traverse (genMonthActivity accounts onBudgetAccs categories) months
  let rawTxs = concatMap snd perMonth
      numberedTxs = zipWith (\i tx -> tx { txId = TransactionId i }) [1 ..] rawTxs

  pure MultiMonthWorld
    { mmwAccounts = accounts
    , mmwCategories = categories
    , mmwMonths = months
    , mmwAssignments = concatMap fst perMonth
    , mmwTransactions = numberedTxs
    }

-- | One month's worth of assignments/transactions for 'genMultiMonthWorld'
-- — the same per-month generation 'genWorld' does, factored out so it
-- can run once per month instead of just once.
genMonthActivity :: [Account] -> [Account] -> [Category] -> YearMonth -> Gen ([Assignment], [Transaction])
genMonthActivity accounts onBudgetAccs categories month = do
  assignments <- traverse (genAssignmentFor month) categories

  nCategorized <- choose (0, 3)
  categorizedTxs <- vectorOf nCategorized (genCategorizedTx month onBudgetAccs categories)

  nInflows <- choose (0, 3)
  inflowTxs <- vectorOf nInflows (genInflowTx month accounts)

  transferTxs <-
    if length onBudgetAccs >= 2
      then do
        nTransfers <- choose (0, 2)
        concat <$> vectorOf nTransfers (genTransferTxs month onBudgetAccs)
      else pure []

  pure (assignments, categorizedTxs ++ inflowTxs ++ transferTxs)
