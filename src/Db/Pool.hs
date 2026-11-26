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

import Data.Pool (Pool, defaultPoolConfig, destroyAllResources, newPool, withResource)
import Database.SQLite.Simple (Connection, close, execute_, open)
import Db.Migrations (runMigrations)
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeDirectory)

-- | Builds the pool for the given SQLite file, sets the agreed pragmas
-- (WAL, foreign_keys, busy_timeout) on every newly opened connection,
-- and runs the migrations once before handing the pool back. Max 8
-- connections, 60 second idle timeout — plenty for a single-user
-- desktop app, small enough to avoid risking "database is locked"
-- storms.
--
-- First creates the parent directory of @dbPath@ if it doesn't exist
-- yet (e.g. a fresh @%APPDATA%\\bucktracker\\@ on the very first start,
-- or a custom subdirectory via BUCKTRACKER_DB_PATH) — otherwise
-- SQLite's @open@ fails with @ErrorCan'tOpen@ before a file can even
-- exist. @createDirectoryIfMissing True@ is idempotent and also works
-- for @:memory:@ (@takeDirectory ":memory:" == "."@, which always
-- exists).
createPool :: FilePath -> IO (Pool Connection)
createPool dbPath = do
  createDirectoryIfMissing True (takeDirectory dbPath)
  pool <- newPool (defaultPoolConfig (openConfigured dbPath) close 60 8)
  withResource pool runMigrations
  pure pool

openConfigured :: FilePath -> IO Connection
openConfigured dbPath = do
  conn <- open dbPath
  execute_ conn "PRAGMA journal_mode = WAL"
  execute_ conn "PRAGMA foreign_keys = ON"
  execute_ conn "PRAGMA busy_timeout = 5000"
  pure conn

withConnection :: Pool Connection -> (Connection -> IO a) -> IO a
withConnection = withResource

-- | Closes every connection in the pool. Mostly relevant in tests: a
-- file-backed db (needed as soon as multiple pool connections must see
-- the same data, since @:memory:@ is its own empty db per connection)
-- needs to go through this before the temp file gets removed —
-- otherwise that blocks on Windows on a still-open handle.
closePool :: Pool Connection -> IO ()
closePool = destroyAllResources
