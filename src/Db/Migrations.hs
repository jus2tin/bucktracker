-- | Migration runner: on startup, automatically applies every not-yet-
-- applied @.sql@ file from @migrations/@ (see DECISIONS.md §7).
--
-- The files themselves are cabal @data-files@; their location on disk
-- comes from the generated 'Paths_bucktracker' module — that works both
-- in a local @stack build@/@stack test@ (resolves to the directory in
-- the checkout then) and after a real install, with no TemplateHaskell.
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

-- | Creates the @schema_migrations@ table if needed, then applies every
-- not-yet-applied migration, in filename order (hence the numbered
-- prefixes like @0001_initial.sql@). Each migration runs in its own
-- transaction: all or nothing per file.
--
-- Fails with a 'Database.SQLite.Simple.SQLError' if a migration is
-- broken — deliberately no attempt at recovery; a broken schema should
-- make the app stop outright, not start up half-working.
runMigrations :: Connection -> IO ()
runMigrations conn = do
  ensureMigrationsTable conn
  applied <- appliedMigrations conn
  -- 'data-files: migrations/*.sql' in package.yaml keeps that relative
  -- path under the datadir: the .sql files live in
  -- @<getDataDir>/migrations/@, not in the datadir itself.
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

-- | Runs the whole file (which can contain multiple @;@-separated
-- statements) via direct-sqlite's 'Raw.exec' — sqlite-simple's own
-- 'execute_' only prepares one statement and would silently ignore the
-- rest of the file.
applyMigration :: Connection -> FilePath -> FilePath -> IO ()
applyMigration conn migrationsDir fileName = withTransaction conn $ do
  sql <- TextIO.readFile (migrationsDir </> fileName)
  Raw.exec (connectionHandle conn) sql
  now <- getCurrentTime
  execute
    conn
    "INSERT INTO schema_migrations (filename, applied_at) VALUES (?, ?)"
    (Text.pack fileName, now)
