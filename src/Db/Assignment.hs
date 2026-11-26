module Db.Assignment
  ( setAssignment
  , listAssignmentsForMonth
  ) where

import Database.SQLite.Simple (Connection, FromRow (..), execute, field, query)
import Db.Field (yearMonthField)
import Domain.Budget (Assignment (Assignment))
import Domain.Types (CategoryId, Cents, YearMonth, ymMonth, ymYear)

instance FromRow Assignment where
  fromRow = Assignment <$> field <*> yearMonthField <*> field

-- | "Upsert": zet (of overschrijft) hoeveel er deze maand aan deze
-- categorie is toegewezen — één rij per (categorie, maand), zie de
-- UNIQUE-constraint in de migratie.
setAssignment :: Connection -> CategoryId -> YearMonth -> Cents -> IO ()
setAssignment conn cid ym amount =
  execute
    conn
    ( "INSERT INTO assignments (category_id, year, month, amount) VALUES (?, ?, ?, ?) \
      \ON CONFLICT (category_id, year, month) DO UPDATE SET amount = excluded.amount"
    )
    (cid, ymYear ym, ymMonth ym, amount)

listAssignmentsForMonth :: Connection -> YearMonth -> IO [Assignment]
listAssignmentsForMonth conn ym =
  query
    conn
    "SELECT category_id, year, month, amount FROM assignments WHERE year = ? AND month = ?"
    (ymYear ym, ymMonth ym)
