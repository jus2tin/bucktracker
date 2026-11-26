-- | Migratie-runner: past bij het opstarten automatisch alle nog niet
-- toegepaste @.sql@-bestanden uit @migrations/@ toe (zie DECISIONS.md §7).
--
-- De bestanden zelf zijn cabal @data-files@; hun locatie op schijf komt van
-- het gegenereerde 'Paths_bucktracker'-module — dat werkt zowel in een
-- lokale @stack build@/@stack test@ (resolvet dan naar de map in de
-- checkout) als na een echte installatie, zonder TemplateHaskell.
module Db.Migrations
  ( runMigrations
  ) where

import Control.Monad (forM_, unless)
import Data.List (sort)
import qualified Data.Set as Set
import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO
import Data.Time (getCurrentTime)
import Database.SQLite.Simple
  ( Connection
  , Only (Only)
  , connectionHandle
  , execute
  , execute_
  , query_
  , withTransaction
  )
import qualified Database.SQLite3 as Raw
import System.Directory (listDirectory)
import System.FilePath (takeExtension, (</>))

import Paths_bucktracker (getDataDir)

-- | Maakt (indien nodig) de @schema_migrations@-tabel en past daarna elke
-- nog niet toegepaste migratie toe, in bestandsnaam-volgorde (vandaar de
-- genummerde prefixen zoals @0001_initial.sql@). Elke migratie draait in
-- haar eigen transactie: alles of niets per bestand.
--
-- Faalt met een 'Database.SQLite.Simple.SQLError' als een migratie kapot
-- is — bewust geen poging tot herstel; een stuk schema moet de app direct
-- laten stoppen, niet half opstarten.
runMigrations :: Connection -> IO ()
runMigrations conn = do
  ensureMigrationsTable conn
  applied <- appliedMigrations conn
  -- 'data-files: migrations/*.sql' in package.yaml behoudt dat relatieve
  -- pad onder de datadir: de .sql-bestanden zitten dus in
  -- @<getDataDir>/migrations/@, niet in de datadir zelf.
  migrationsDir <- (</> "migrations") <$> getDataDir
  pendingFiles <-
    sort . filter (\f -> takeExtension f == ".sql") <$> listDirectory migrationsDir
  forM_ pendingFiles $ \fileName ->
    unless (fileName `Set.member` applied) $
      applyMigration conn migrationsDir fileName

ensureMigrationsTable :: Connection -> IO ()
ensureMigrationsTable conn =
  execute_
    conn
    "CREATE TABLE IF NOT EXISTS schema_migrations \
    \(filename TEXT PRIMARY KEY, applied_at TEXT NOT NULL)"

appliedMigrations :: Connection -> IO (Set.Set FilePath)
appliedMigrations conn = do
  rows <- query_ conn "SELECT filename FROM schema_migrations" :: IO [Only Text.Text]
  pure (Set.fromList [Text.unpack fileName | Only fileName <- rows])

-- | Draait het hele bestand (kan meerdere @;@-gescheiden statements
-- bevatten) via direct-sqlite's 'Raw.exec' — sqlite-simple's eigen
-- 'execute_' bereidt maar één statement voor en zou de rest van het
-- bestand stilzwijgend negeren.
applyMigration :: Connection -> FilePath -> FilePath -> IO ()
applyMigration conn migrationsDir fileName = withTransaction conn $ do
  sql <- TextIO.readFile (migrationsDir </> fileName)
  Raw.exec (connectionHandle conn) sql
  now <- getCurrentTime
  execute
    conn
    "INSERT INTO schema_migrations (filename, applied_at) VALUES (?, ?)"
    (Text.pack fileName, now)
