-- | Test helper, not a *Spec.hs — hspec-discover therefore doesn't pick
-- this up as a standalone test, only as an import from the real
-- Db.*Spec modules.
module Db.Setup
  ( withTestDb
  , expectRight
  ) where

import Control.Exception (bracket)
import Database.SQLite.Simple (Connection, close, execute_, open)
import Db.Migrations (runMigrations)
import Test.Hspec (expectationFailure)

-- | A fresh @:memory:@ connection, with migrations already run over it
-- (DECISIONS.md §7: "a fresh :memory: connection per test") — use this
-- with hspec's 'Test.Hspec.around'.
withTestDb :: (Connection -> IO a) -> IO a
withTestDb = bracket openTestConnection close

openTestConnection :: IO Connection
openTestConnection = do
  conn <- open ":memory:"
  execute_ conn "PRAGMA foreign_keys = ON"
  runMigrations conn
  pure conn

-- | Unwraps an @Either e a@ without a partial pattern (@Right x <-@) in
-- the tests: on 'Left', the test fails with a decent message instead of
-- a cryptic pattern-match exception. The 'error' afterward is
-- deliberately unreachable — 'expectationFailure' always throws — and
-- exists only to make it typecheck as @IO a@.
expectRight :: Show e => Either e a -> IO a
expectRight = either (\e -> expectationFailure (show e) >> error "unreachable") pure
