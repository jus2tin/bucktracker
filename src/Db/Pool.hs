-- | Connection pool around SQLite (see DECISIONS.md §7).
--
-- Every other @Db.*@ module works with a plain 'Connection', never with
-- the 'Pool' itself — that keeps repository functions and tests
-- pool-independent (a test just opens its own @:memory:@ 'Connection'
-- and calls 'Db.Migrations.runMigrations' + the repository functions
-- directly, no pool needed). The pool is purely infrastructure for the
-- (later) Api layer: each request borrows one 'Connection', uses it, and
-- returns it.
module Db.Pool
  ( Pool
  , createPool
  , withConnection
  , closePool
  ) where

import Control.Exception (SomeException, bracketOnError, onException, try)
import Data.Pool (Pool, defaultPoolConfig, destroyAllResources, newPool, setNumStripes, withResource)
import Data.Text (Text)
import Database.SQLite.Simple (Connection, Only, close, execute_, open, query_)
import Db.Migrations (runMigrations)
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeDirectory)

-- | Builds the pool for the given SQLite file and runs the migrations
-- once before handing the pool back (Track B §1.2). Max 4 connections,
-- 60 second idle timeout: SQLite is single-writer regardless of pool
-- size, so a larger pool only buys more concurrent *readers* in WAL
-- mode, at the cost of more contention on that one writer — 4 is
-- plenty for a single-user desktop app, small enough to avoid risking
-- "database is locked" storms.
--
-- First creates the parent directory of @dbPath@ if it doesn't exist
-- yet (e.g. a fresh @%APPDATA%\\bucktracker\\@ on the very first start,
-- or a custom subdirectory via BUCKTRACKER_DB_PATH) — otherwise
-- SQLite's @open@ fails with @ErrorCan'tOpen@ before a file can even
-- exist. @createDirectoryIfMissing True@ is idempotent and also works
-- for @:memory:@ (@takeDirectory ":memory:" == "."@, which always
-- exists).
--
-- @journal_mode = WAL@ is set exactly once here, on a single borrowed
-- connection, rather than on every connection 'openConfigured' opens:
-- it's persisted in the database file's own header, not per-connection
-- state, so repeating it on each new pooled connection only risked a
-- @PRAGMA journal_mode = WAL@ racing a concurrent writer before
-- @busy_timeout@ was even set on that connection (Track B §1.1). If
-- anything after the pool exists throws, 'closePool' still runs, so a
-- connection opened here is never leaked.
--
-- Pinned to a single stripe ('setNumStripes' (Just 1)): @resource-pool@
-- otherwise stripes by @getNumCapabilities@, and refuses to create a
-- pool with fewer resources than stripes — on any machine with more
-- than 4 cores that would make @poolMaxResources = 4@ itself fail
-- outright. SQLite is single-writer regardless, so there's no
-- concurrency benefit to striping here to lose.
createPool :: FilePath -> IO (Pool Connection)
createPool dbPath = do
  createDirectoryIfMissing True (takeDirectory dbPath)
  pool <- newPool (setNumStripes (Just 1) (defaultPoolConfig (openConfigured dbPath) close 60 4))
  withResource pool setUpOnce `onException` closePool pool
  pure pool
  where
    setUpOnce conn = do
      _ <- query_ conn "PRAGMA journal_mode = WAL" :: IO [Only Text]
      execute_ conn "PRAGMA wal_autocheckpoint = 1000"
      runMigrations conn

-- | Every pooled connection gets the same pragma sequence, in this
-- exact order (Track B §1.2): @busy_timeout@ MUST be set first — it's
-- what makes SQLite *wait* (instead of failing immediately with
-- @SQLITE_BUSY@) if this connection's very first statement finds the
-- writer connection mid-transaction. Wrapped in 'bracketOnError' so a
-- failure partway through this setup (an unlikely but not impossible
-- @PRAGMA@ failure) still closes the half-configured connection
-- instead of leaking it.
openConfigured :: FilePath -> IO Connection
openConfigured dbPath = bracketOnError (open dbPath) close $ \conn -> do
  execute_ conn "PRAGMA busy_timeout = 5000"
  execute_ conn "PRAGMA foreign_keys = ON"
  execute_ conn "PRAGMA synchronous = NORMAL"
  execute_ conn "PRAGMA temp_store = MEMORY"
  pure conn

withConnection :: Pool Connection -> (Connection -> IO a) -> IO a
withConnection = withResource

-- | Closes every connection in the pool — but first, best-effort,
-- folds the WAL file cleanly back into the main database file
-- (@PRAGMA wal_checkpoint(TRUNCATE)@, Track B §1.2): otherwise a
-- @.db-wal@ left behind at shutdown only gets reconciled the next time
-- something opens the database, instead of on a clean exit. A failure
-- here (e.g. the file already gone) is swallowed, since closing the
-- pool must still proceed either way. Also needed in tests: a
-- file-backed db (needed as soon as multiple pool connections must see
-- the same data, since @:memory:@ is its own empty db per connection)
-- needs every connection closed before its temp file gets removed —
-- otherwise that blocks on Windows on a still-open handle.
closePool :: Pool Connection -> IO ()
closePool pool = do
  _ <- try @SomeException (withResource pool (\conn -> execute_ conn "PRAGMA wal_checkpoint(TRUNCATE)"))
  destroyAllResources pool
