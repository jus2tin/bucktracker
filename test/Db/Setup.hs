-- | Test-helper, geen *Spec.hs — hspec-discover pikt dit dus niet op als
-- een losse test, alleen als import vanuit de echte Db.*Spec-modules.
module Db.Setup
  ( withTestDb
  , expectRight
  ) where

import Control.Exception (bracket)
import Database.SQLite.Simple (Connection, close, execute_, open)
import Db.Migrations (runMigrations)
import Test.Hspec (expectationFailure)

-- | Een verse @:memory:@-connectie, migraties er al overheen gedraaid
-- (DECISIONS.md §7: "verse :memory:-connectie per test") — gebruik dit met
-- hspec's 'Test.Hspec.around'.
withTestDb :: (Connection -> IO a) -> IO a
withTestDb = bracket openTestConnection close

openTestConnection :: IO Connection
openTestConnection = do
  conn <- open ":memory:"
  execute_ conn "PRAGMA foreign_keys = ON"
  runMigrations conn
  pure conn

-- | Ontleedt een @Either e a@ zonder een partial pattern (@Right x <-@) in
-- de tests: bij 'Left' faalt de test met een nette boodschap i.p.v. een
-- cryptische pattern-match-exceptie. De 'error' hierna is bewust
-- onbereikbaar — 'expectationFailure' gooit altijd een exceptie — en
-- bestaat alleen om het als @IO a@ te laten typechecken.
expectRight :: Show e => Either e a -> IO a
expectRight = either (\e -> expectationFailure (show e) >> error "unreachable") pure

