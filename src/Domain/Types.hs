-- | Fundamentele domeintypes: geld, maanden, ID's en simpele enums.
--
-- Alles hier is total: er wordt nergens @error@, @head@ of @fromJust@
-- gebruikt. Waar een waarde ongeldig kan zijn, geeft de smart constructor
-- een 'Either' 'Domain.Error.DomainError' terug in plaats van te crashen.
module Domain.Types
  ( -- * Geld
    Cents
  , zeroCents
  , cents
  , centsValue
  , negateCents
  , scaleCents
  , splitEvenly

    -- * Maanden
  , YearMonth
  , ymYear
  , ymMonth
  , mkYearMonth
  , dayToYearMonth
  , nextYearMonth
  , prevYearMonth

    -- * ID's
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
  ) where

import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as NE
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Time (Day, toGregorian)
import Domain.Error (DomainError (..))

-- | Een geldbedrag in gehele centen. Nooit 'Double'/'Float'. Bewust geen
-- 'Num'-instance (zodat "centen keer centen" niet per ongeluk compileert);
-- optellen gaat via het 'Monoid' (som), en 'scaleCents' voor een geheel
-- veelvoud.
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

-- | Vermenigvuldig met een geheel getal (bv. "x maanden vooruit sparen").
scaleCents :: Int64 -> Cents -> Cents
scaleCents factor (Cents c) = Cents (factor * c)

-- | Verdeel een bedrag zo gelijk mogelijk over @n@ regels (bv. een split-
-- transactie). De som van het resultaat is altijd *exact* gelijk aan het
-- origineel; eventuele afrondingscenten gaan naar de eerste regels. Voor
-- @n <= 0@ komt het hele bedrag in één regel terecht — "splitsen in niets"
-- bestaat niet, dus dit is de enige zinnige, total betekenis.
splitEvenly :: Cents -> Int -> NonEmpty Cents
splitEvenly total n = fromMaybe (total :| []) (NE.nonEmpty parts)
  where
    count = max 1 n
    totalValue = centsValue total
    (base, remainder) = totalValue `quotRem` fromIntegral count
    bumps = replicate (fromIntegral (abs remainder)) (signum remainder) ++ repeat 0
    parts = [ Cents (base + b) | b <- take count bumps ]

-- | Een kalendermaand (budgetperiode). De constructor wordt niet
-- geëxporteerd: een 'YearMonth' is alleen te maken via 'mkYearMonth' of
-- 'dayToYearMonth', dus @ymMonth@ ligt altijd in @[1,12]@.
data YearMonth = YearMonth
  { ymYear  :: Int
  , ymMonth :: Int
  } deriving stock (Eq, Ord, Show)

-- | Smart constructor: 'Left' ('InvalidMonth' m) als de maand buiten
-- @[1,12]@ valt.
mkYearMonth :: Int -> Int -> Either DomainError YearMonth
mkYearMonth y m
  | m >= 1 && m <= 12 = Right (YearMonth y m)
  | otherwise = Left (InvalidMonth m)

dayToYearMonth :: Day -> YearMonth
dayToYearMonth day =
  let (y, m, _) = toGregorian day
  in YearMonth (fromIntegral y) m

-- | Totaal over @Int@: ook op een (via de verborgen constructor
-- onmogelijke) ongeldige maand loopt dit niet vast, het telt gewoon door.
nextYearMonth :: YearMonth -> YearMonth
nextYearMonth (YearMonth y 12) = YearMonth (y + 1) 1
nextYearMonth (YearMonth y m)  = YearMonth y (m + 1)

prevYearMonth :: YearMonth -> YearMonth
prevYearMonth (YearMonth y 1) = YearMonth (y - 1) 12
prevYearMonth (YearMonth y m) = YearMonth y (m - 1)

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

-- | Hash van een geïmporteerde brontransactie (CSV/CAMT.053, fase later),
-- gebruikt om herimport te dedupliceren. Nog ongebruikt in v0.1.
newtype ImportHash = ImportHash Text
  deriving stock (Eq, Ord, Show)

-- | Checking/Savings/Cash zijn "on-budget"; Tracking telt niet mee voor
-- Ready to Assign (bv. beleggingen).
data AccountType = Checking | Savings | Cash | Tracking
  deriving stock (Eq, Ord, Show, Enum, Bounded)

isOnBudgetType :: AccountType -> Bool
isOnBudgetType Tracking = False
isOnBudgetType _        = True

-- | Canonieke tekstrepresentatie, gebruikt zowel als SQLite TEXT-waarde
-- (Db.Field) als HTML-formulierwaarde (Api) — één bron van waarheid in
-- plaats van de mapping op twee plekken te dupliceren.
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
