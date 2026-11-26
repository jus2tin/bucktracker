-- | 'FromField'/'ToField' instances that connect the Domain newtypes to
-- SQLite columns.
--
-- These are unavoidably orphan instances (neither the class nor the
-- types come from this module) — deliberately bundled here instead of
-- scattered around, so the "bridge" between domain and storage lives in
-- one place. 'YearMonth' doesn't get its own instance: it's stored as
-- two columns (year, month) (see DECISIONS.md §7), hence
-- 'yearMonthField' below instead of a 'FromField'/'ToField' pair.
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

-- * IDs and money amounts: simple newtype wrappers around an already-supported type.

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

-- * Enums, as TEXT (readable in a DB browser, and the SQL CHECK
-- constraints in the migrations pin down the same valid values). The
-- text <-> value mapping itself lives in Domain.Types (canonical, also
-- used by the Api layer for form values) — this is just the connection
-- to FromField/ToField.

instance ToField AccountType where
  toField = SQLText . accountTypeToText

instance FromField AccountType where
  fromField = parseTextField "AccountType" accountTypeFromText

instance ToField TransactionStatus where
  toField = SQLText . transactionStatusToText

instance FromField TransactionStatus where
  fromField = parseTextField "TransactionStatus" transactionStatusFromText

-- | Shared helper for "TEXT column with a fixed set of valid values".
parseTextField :: Typeable a => String -> (Text.Text -> Maybe a) -> Field -> Ok a
parseTextField typeName fromText f = case fieldData f of
  SQLText t -> case fromText t of
    Just v  -> Ok v
    Nothing -> returnError ConversionFailed f ("unknown " ++ typeName ++ ": " ++ Text.unpack t)
  _ -> returnError Incompatible f ("expected a text column for " ++ typeName)

-- 'Day' and 'UTCTime' already have a 'FromField'/'ToField' in
-- sqlite-simple itself (as TEXT, "YYYY-MM-DD" resp. ISO8601-ish, so
-- sortable and consistent with our own TEXT columns) — no instance of
-- our own needed.

-- | 'YearMonth' reads itself from the *two* columns immediately at this
-- position in the row (year, month) — use this instead of 'field' at
-- the spot where a 'YearMonth' belongs in a 'FromRow' instance.
--
-- 'RowParser' has no 'MonadFail' to report an invalid combination with;
-- instead, the month gets validated via its own 'FieldParser' (the same
-- error-reporting machinery as a normal 'FromField' instance), with the
-- year as a free variable in it.
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
