-- | Fundamental domain types: money, months, IDs and simple enums.
--
-- Everything here is total: @error@, @head@ and @fromJust@ are never
-- used. Where a value could be invalid, the smart constructor returns an
-- 'Either' 'Domain.Error.DomainError' instead of crashing.
module Domain.Types
  ( -- * Money
    Cents
  , zeroCents
  , cents
  , centsValue
  , negateCents
  , scaleCents
  , splitEvenly

    -- * Months
  , YearMonth
  , ymYear
  , ymMonth
  , mkYearMonth
  , dayToYearMonth
  , nextYearMonth
  , prevYearMonth
  , yearMonthToText
  , parseYearMonth

    -- * IDs
  , AccountId (..)
  , CategoryGroupId (..)
  , CategoryId (..)
  , TransactionId (..)
  , TransferId (..)
  , ImportHash (..)

    -- * Enums
  , AccountType (..)
  , isOnBudgetType
  , accountTypeToText
  , accountTypeFromText
  , TransactionStatus (..)
  , transactionStatusToText
  , transactionStatusFromText
  , toggleCleared
  ) where

import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as NE
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Read as TextRead
import Data.Time (Day, toGregorian)
import Domain.Error (DomainError (..))

-- | A money amount in whole cents. Never 'Double'/'Float'. Deliberately
-- no 'Num' instance (so "cents times cents" doesn't accidentally
-- compile); addition goes through the 'Monoid' (sum), and 'scaleCents'
-- for multiplying by a whole number.
newtype Cents = Cents Int64
  deriving stock (Eq, Ord, Show)

instance Semigroup Cents where
  Cents a <> Cents b = Cents (a + b)

instance Monoid Cents where
  mempty = Cents 0

zeroCents :: Cents
zeroCents = mempty

cents :: Int64 -> Cents
cents = Cents

centsValue :: Cents -> Int64
centsValue (Cents c) = c

negateCents :: Cents -> Cents
negateCents (Cents c) = Cents (negate c)

-- | Multiply by a whole number (e.g. "save x months ahead").
scaleCents :: Int64 -> Cents -> Cents
scaleCents factor (Cents c) = Cents (factor * c)

-- | Split an amount as evenly as possible across @n@ lines (e.g. a split
-- transaction). The sum of the result is always *exactly* equal to the
-- original; any rounding cents go to the first lines. For @n <= 0@ the
-- whole amount ends up in a single line — "splitting into nothing"
-- doesn't exist, so this is the only sensible, total meaning.
splitEvenly :: Cents -> Int -> NonEmpty Cents
splitEvenly total n = fromMaybe (total :| []) (NE.nonEmpty parts)
  where
    count = max 1 n
    totalValue = centsValue total
    (base, remainder) = totalValue `quotRem` fromIntegral count
    bumps = replicate (fromIntegral (abs remainder)) (signum remainder) ++ repeat 0
    parts = [ Cents (base + b) | b <- take count bumps ]

-- | A calendar month (budget period). The constructor isn't exported: a
-- 'YearMonth' can only be made via 'mkYearMonth' or 'dayToYearMonth', so
-- @ymMonth@ always lies in @[1,12]@.
data YearMonth = YearMonth
  { ymYear  :: Int
  , ymMonth :: Int
  } deriving stock (Eq, Ord, Show)

-- | Smart constructor: 'Left' ('InvalidMonth' m) if the month is outside
-- @[1,12]@.
mkYearMonth :: Int -> Int -> Either DomainError YearMonth
mkYearMonth y m
  | m >= 1 && m <= 12 = Right (YearMonth y m)
  | otherwise = Left (InvalidMonth m)

dayToYearMonth :: Day -> YearMonth
dayToYearMonth day =
  let (y, m, _) = toGregorian day
  in YearMonth (fromIntegral y) m

-- | Total over @Int@: even on an (impossible, given the hidden
-- constructor) invalid month this doesn't get stuck, it just keeps
-- counting.
nextYearMonth :: YearMonth -> YearMonth
nextYearMonth (YearMonth y 12) = YearMonth (y + 1) 1
nextYearMonth (YearMonth y m)  = YearMonth y (m + 1)

prevYearMonth :: YearMonth -> YearMonth
prevYearMonth (YearMonth y 1) = YearMonth (y - 1) 12
prevYearMonth (YearMonth y m) = YearMonth y (m - 1)

-- | @"YYYY-MM"@ — the one canonical text form, used both for the
-- @?month=@ query parameter and for displaying the currently viewed
-- month ("\<- Prev | YYYY-MM | Next -\>").
yearMonthToText :: YearMonth -> Text
yearMonthToText (YearMonth y m) = pad4 y <> "-" <> pad2 m
  where
    pad4 n = let s = show n in Text.pack (replicate (max 0 (4 - length s)) '0' ++ s)
    pad2 n = let s = show n in Text.pack (replicate (max 0 (2 - length s)) '0' ++ s)

-- | The inverse of 'yearMonthToText', total and without
-- 'Prelude.read'. Rejects an out-of-range month the same way
-- 'mkYearMonth' does (just as 'Maybe', not 'Either' — a bad
-- @?month=@ is handled the same as a missing one, see
-- "Api.Budget"\/"Api.Transactions").
parseYearMonth :: Text -> Maybe YearMonth
parseYearMonth t = case Text.splitOn "-" t of
  [yText, mText] -> do
    y <- parseDecimal yText
    m <- parseDecimal mText
    either (const Nothing) Just (mkYearMonth y m)
  _ -> Nothing
  where
    parseDecimal s = case TextRead.decimal s of
      Right (n, rest) | Text.null rest -> Just n
      _                                -> Nothing

newtype AccountId = AccountId Int64
  deriving stock (Eq, Ord, Show)

newtype CategoryGroupId = CategoryGroupId Int64
  deriving stock (Eq, Ord, Show)

newtype CategoryId = CategoryId Int64
  deriving stock (Eq, Ord, Show)

newtype TransactionId = TransactionId Int64
  deriving stock (Eq, Ord, Show)

newtype TransferId = TransferId Int64
  deriving stock (Eq, Ord, Show)

-- | Hash of an imported source transaction (CSV/CAMT.053, a later
-- phase), used to deduplicate re-imports. Still unused in v0.1.
newtype ImportHash = ImportHash Text
  deriving stock (Eq, Ord, Show)

-- | Checking/Savings/Cash are "on-budget"; Tracking doesn't count toward
-- Ready to Assign (e.g. investments).
data AccountType = Checking | Savings | Cash | Tracking
  deriving stock (Eq, Ord, Show, Enum, Bounded)

isOnBudgetType :: AccountType -> Bool
isOnBudgetType Tracking = False
isOnBudgetType _        = True

-- | Canonical text representation, used both as the SQLite TEXT value
-- (Db.Field) and as the HTML form value (Api) — a single source of
-- truth instead of duplicating the mapping in two places.
accountTypeToText :: AccountType -> Text
accountTypeToText Checking = "checking"
accountTypeToText Savings  = "savings"
accountTypeToText Cash     = "cash"
accountTypeToText Tracking = "tracking"

accountTypeFromText :: Text -> Maybe AccountType
accountTypeFromText "checking" = Just Checking
accountTypeFromText "savings"  = Just Savings
accountTypeFromText "cash"     = Just Cash
accountTypeFromText "tracking" = Just Tracking
accountTypeFromText _          = Nothing

data TransactionStatus = Uncleared | Cleared | Reconciled
  deriving stock (Eq, Ord, Show, Enum, Bounded)

transactionStatusToText :: TransactionStatus -> Text
transactionStatusToText Uncleared  = "uncleared"
transactionStatusToText Cleared    = "cleared"
transactionStatusToText Reconciled = "reconciled"

transactionStatusFromText :: Text -> Maybe TransactionStatus
transactionStatusFromText "uncleared"  = Just Uncleared
transactionStatusFromText "cleared"    = Just Cleared
transactionStatusFromText "reconciled" = Just Reconciled
transactionStatusFromText _            = Nothing

-- | Toggling a transaction's cleared state from the register:
-- 'Uncleared' becomes 'Cleared' and back. A 'Reconciled' transaction is
-- a no-op here — reconciling is a deliberate, account-wide action (see
-- 'Db.Transaction.reconcileAccount'/'Domain.Budget.clearedBalance'),
-- not something a single click on one row should be able to undo.
toggleCleared :: TransactionStatus -> TransactionStatus
toggleCleared Uncleared  = Cleared
toggleCleared Cleared    = Uncleared
toggleCleared Reconciled = Reconciled
