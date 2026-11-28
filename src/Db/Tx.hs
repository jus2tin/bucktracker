-- | Explicit SQLite transaction wrappers (Track B §1.3), replacing bare
-- @Database.SQLite.Simple.withTransaction@ (@BEGIN DEFERRED@) on every
-- write path.
--
-- SQLite's deferred transaction only takes its read lock up front; it
-- discovers it needs the write lock the moment the first @INSERT@\/
-- @UPDATE@\/@DELETE@ inside it actually runs, and SQLite refuses to
-- *wait* for that upgrade (waiting could deadlock two simultaneous
-- deferred readers each hoping to become the sole writer) — it fails
-- immediately with @SQLITE_BUSY@ instead, even though @busy_timeout@ is
-- set. 'withImmediateTransaction' avoids that failure mode by asking
-- for the write lock immediately, so a second writer simply waits (up
-- to @busy_timeout@, in FIFO order) instead of erroring out under
-- everyday contention.
module Db.Tx
  ( withImmediateTransaction
  , withReadSnapshot
  ) where

import Control.Exception (SomeException, mask, onException, try)
import Control.Monad (void)
import Database.SQLite.Simple (Connection, execute_)

-- | Every multi-step *write* (an insert/update/delete spanning more
-- than one statement, or a read-then-write precondition check that
-- must see a consistent snapshot) goes through this instead of a bare
-- @withTransaction@ — see the module header. Acquires SQLite's
-- @RESERVED@ write lock immediately (@BEGIN IMMEDIATE@), runs @action@,
-- then commits; on any exception, best-effort rolls back (ignoring any
-- secondary failure from the rollback itself, e.g. the connection
-- already being gone) before re-raising the original exception.
-- 'mask'ed so an asynchronous exception can never land between
-- @BEGIN@/@COMMIT@ and its matching rollback.
withImmediateTransaction :: Connection -> IO a -> IO a
withImmediateTransaction conn action = mask $ \restore -> do
  execute_ conn "BEGIN IMMEDIATE"
  result <- restore action `onException` ignoringExceptions (execute_ conn "ROLLBACK")
  execute_ conn "COMMIT"
  pure result

-- | A consistent, point-in-time read-only snapshot across several
-- @SELECT@s on the same 'Connection' (e.g. every 'Db.listAllTransactions'/
-- 'Db.listAllAssignments'/'Db.listAccounts' a page render folds
-- together): in SQLite's WAL mode, a @BEGIN DEFERRED@ that never writes
-- holds its snapshot open until @COMMIT@, so none of those reads can
-- see a write that lands on a *different* connection partway through
-- the render. Same shape as 'withImmediateTransaction' otherwise, but
-- never contends for the write lock.
withReadSnapshot :: Connection -> IO a -> IO a
withReadSnapshot conn action = mask $ \restore -> do
  execute_ conn "BEGIN DEFERRED"
  result <- restore action `onException` ignoringExceptions (execute_ conn "ROLLBACK")
  execute_ conn "COMMIT"
  pure result

ignoringExceptions :: IO () -> IO ()
ignoringExceptions io = void (try @SomeException io)
