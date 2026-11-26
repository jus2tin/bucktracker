-- | Gedeelde 'Arbitrary'-instances en generators voor de Domain-tests.
--
-- Geen productiecode (orphan instances zijn hier bewust, zoals gebruikelijk
-- in testsuites), maar wel total: generators die kunnen "mislukken" (bv.
-- een smart constructor die een 'Either' teruggeeft) proberen het gewoon
-- opnieuw in plaats van te crashen — ze worden altijd met geldige invoer
-- aangeroepen, dus dat pad is onbereikbaar maar nooit onveilig.
module Domain.Gen
  ( genCents
  , genYearMonth
  , genDayIn
  , genAccount
  , genCategory
  , World (..)
  , genWorld
  ) where

import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.Text as Text
import Data.Time (Day, fromGregorian)
import Domain.Account (Account (..), mkAccount)
import Domain.Budget (Assignment (..), CategoryMonth (..))
import Domain.Category (Category (..), mkCategory)
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

-- * Basistypes

-- | Begrensd tot +/- 1.000.000,00 EUR zodat sommen over lijsten van
-- redelijke lengte nooit richting de grenzen van 'Data.Int.Int64' komen.
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
    Left _   -> genYearMonth -- onbereikbaar: m zit al in [1,12]

instance Arbitrary YearMonth where
  arbitrary = genYearMonth

genDayIn :: YearMonth -> Gen Day
genDayIn ym = do
  d <- choose (1, 28) -- 28: geldig in elke maand, geen kalenderrekenwerk nodig
  pure (fromGregorian (fromIntegral (ymYear ym)) (ymMonth ym) d)

instance Arbitrary Day where
  arbitrary = genYearMonth >>= genDayIn

-- Kleine, bewust overlappende ranges: zo levert equality tussen twee
-- onafhankelijk gegenereerde ID's regelmatig zowel True als False op, wat
-- nodig is om filterlogica (bv. "alleen regels van déze categorie") goed
-- te testen.
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

-- | Losse, op zichzelf staande transacties (geen wereld met kloppende
-- rekeningen/categorieën erbij) — bruikbaar voor structurele eigenschappen
-- zoals "een transactie raakt alleen zijn eigen rekening".
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

-- * Entiteiten via de echte smart constructors

genAccount :: Int -> AccountType -> Gen Account
genAccount n ty =
  case mkAccount (AccountId (fromIntegral n)) (Text.pack ("Account " ++ show n)) ty of
    Right acc -> pure acc
    Left _    -> genAccount n ty -- onbereikbaar: de naam is nooit leeg

genCategory :: Int -> CategoryGroupId -> Gen Category
genCategory n gid =
  case mkCategory (CategoryId (fromIntegral n)) gid (Text.pack ("Category " ++ show n)) of
    Right cat -> pure cat
    Left _    -> genCategory n gid -- onbereikbaar: de naam is nooit leeg

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
  pure (mkSpendingTransaction (TransactionId 0) (accId acc) day "Boodschappen" status
          (firstLine :| extraLines) Nothing)

genInflowTx :: YearMonth -> [Account] -> Gen Transaction
genInflowTx month accounts = do
  acc <- elements accounts
  day <- genDayIn month
  status <- arbitrary
  amt <- genCents
  pure (mkInflowTransaction (TransactionId 0) (accId acc) day "Inkomen" status amt Nothing)

genDistinctPair :: [Account] -> Gen (Account, Account)
genDistinctPair accs = do
  a <- elements accs
  b <- elements accs
  if accId a == accId b then genDistinctPair accs else pure (a, b)

-- | Beide legs van een transfer, altijd tussen twee *verschillende*
-- on-budget rekeningen (zie DECISIONS.md §3 voor waarom een gemengde
-- on-budget/tracking-transfer hier bewust niet gegenereerd wordt).
genTransferTxs :: YearMonth -> [Account] -> Gen [Transaction]
genTransferTxs month onBudgetAccs = do
  (fromAcc, toAcc) <- genDistinctPair onBudgetAccs
  day <- genDayIn month
  status <- arbitrary
  amt <- genCents
  case mkTransferPair (TransferId 0) (TransactionId 0, accId fromAcc) (TransactionId 0, accId toAcc)
         day status amt of
    Right (legA, legB) -> pure [legA, legB]
    Left _             -> pure [] -- onbereikbaar: fromAcc /= toAcc gegarandeerd

genAssignmentFor :: YearMonth -> Category -> Gen Assignment
genAssignmentFor month cat = Assignment (catId cat) month <$> genCents

-- * Een complete, interne-consistente boekhouding

-- | Een "wereld": rekeningen, categorieën, toewijzingen en transacties die
-- intern consistent zijn (elke categorie/rekening die een transactie of
-- toewijzing noemt, bestaat ook echt) — nodig om de ledger-brede invariant
-- (invariant 1) zinvol te kunnen testen. Zie 'Domain.Budget.budgetBalancesAccounts'.
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
