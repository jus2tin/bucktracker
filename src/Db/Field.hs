-- | 'FromField'/'ToField' instances die de Domain-newtypes aan SQLite-
-- kolommen koppelen.
--
-- Dit zijn onvermijdelijk orphan instances (noch de klasse, noch de types
-- komen uit dit module) — bewust hier gebundeld in plaats van verspreid,
-- zodat de "brug" tussen domein en opslag op één plek staat. 'YearMonth'
-- heeft geen eigen instance: die wordt als twee kolommen (year, month)
-- opgeslagen (zie DECISIONS.md §7), vandaar 'yearMonthField' hieronder in
-- plaats van een 'FromField'/'ToField'-paar.
module Db.Field
  ( yearMonthField
  ) where

import qualified Data.Text as Text
import Data.Typeable (Typeable)
import Database.SQLite.Simple (SQLData (SQLText), field)
import Database.SQLite.Simple.FromField
  ( Field
  , FromField (..)
  , ResultError (ConversionFailed, Incompatible)
  , fieldData
  , returnError
  )
import Database.SQLite.Simple.FromRow (RowParser, fieldWith)
import Database.SQLite.Simple.Ok (Ok (Errors, Ok))
import Database.SQLite.Simple.ToField (ToField (..))
import Domain.Types

-- * ID's en geldbedragen: simpele newtype-wrappers rond een al ondersteund type.

instance ToField AccountId where
  toField (AccountId i) = toField i

instance FromField AccountId where
  fromField f = AccountId <$> fromField f

instance ToField CategoryGroupId where
  toField (CategoryGroupId i) = toField i

instance FromField CategoryGroupId where
  fromField f = CategoryGroupId <$> fromField f

instance ToField CategoryId where
  toField (CategoryId i) = toField i

instance FromField CategoryId where
  fromField f = CategoryId <$> fromField f

instance ToField TransactionId where
  toField (TransactionId i) = toField i

instance FromField TransactionId where
  fromField f = TransactionId <$> fromField f

instance ToField TransferId where
  toField (TransferId i) = toField i

instance FromField TransferId where
  fromField f = TransferId <$> fromField f

instance ToField ImportHash where
  toField (ImportHash t) = toField t

instance FromField ImportHash where
  fromField f = ImportHash <$> fromField f

instance ToField Cents where
  toField = toField . centsValue

instance FromField Cents where
  fromField f = cents <$> fromField f

-- * Enums, als TEXT (leesbaar in een DB-browser, en de SQL CHECK-
-- constraints in de migraties leggen dezelfde geldige waarden vast).

instance ToField AccountType where
  toField = SQLText . accountTypeToText

instance FromField AccountType where
  fromField = parseTextField "AccountType" accountTypeFromText

accountTypeToText :: AccountType -> Text.Text
accountTypeToText Checking = "checking"
accountTypeToText Savings  = "savings"
accountTypeToText Cash     = "cash"
accountTypeToText Tracking = "tracking"

accountTypeFromText :: Text.Text -> Maybe AccountType
accountTypeFromText "checking" = Just Checking
accountTypeFromText "savings"  = Just Savings
accountTypeFromText "cash"     = Just Cash
accountTypeFromText "tracking" = Just Tracking
accountTypeFromText _          = Nothing

instance ToField TransactionStatus where
  toField = SQLText . transactionStatusToText

instance FromField TransactionStatus where
  fromField = parseTextField "TransactionStatus" transactionStatusFromText

transactionStatusToText :: TransactionStatus -> Text.Text
transactionStatusToText Uncleared  = "uncleared"
transactionStatusToText Cleared    = "cleared"
transactionStatusToText Reconciled = "reconciled"

transactionStatusFromText :: Text.Text -> Maybe TransactionStatus
transactionStatusFromText "uncleared"  = Just Uncleared
transactionStatusFromText "cleared"    = Just Cleared
transactionStatusFromText "reconciled" = Just Reconciled
transactionStatusFromText _            = Nothing

-- | Gedeelde helper voor "TEXT-kolom met een vaste set geldige waarden".
parseTextField :: Typeable a => String -> (Text.Text -> Maybe a) -> Field -> Ok a
parseTextField typeName fromText f = case fieldData f of
  SQLText t -> case fromText t of
    Just v  -> Ok v
    Nothing -> returnError ConversionFailed f ("unknown " ++ typeName ++ ": " ++ Text.unpack t)
  _ -> returnError Incompatible f ("expected a text column for " ++ typeName)

-- 'Day' en 'UTCTime' hebben al een 'FromField'/'ToField' in sqlite-simple
-- zelf (als TEXT, "YYYY-MM-DD" resp. ISO8601-achtig, dus sorteerbaar en
-- consistent met onze eigen TEXT-kolommen) — geen eigen instance nodig.

-- | 'YearMonth' leest zichzelf uit de *twee* kolommen die onmiddellijk op
-- deze positie in de rij staan (year, month) — gebruik dit in plaats van
-- 'field' op de plek waar een 'YearMonth' in een 'FromRow'-instance hoort.
--
-- 'RowParser' heeft geen 'MonadFail' om een ongeldige combinatie te
-- melden; in plaats daarvan valideert de maand via een eigen
-- 'FieldParser' (dezelfde foutmelding-machinerie als een gewone
-- 'FromField'-instance), met het jaar als vrije variabele erin.
yearMonthField :: RowParser YearMonth
yearMonthField = do
  y <- field
  fieldWith (monthField y)

monthField :: Int -> Field -> Ok YearMonth
monthField y f = case (fromField f :: Ok Int) of
  Errors es -> Errors es
  Ok m -> case mkYearMonth y m of
    Right ym -> Ok ym
    Left _ -> returnError ConversionFailed f "invalid month in (year, month) pair"
