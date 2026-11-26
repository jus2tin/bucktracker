-- | Test helper, not a *Spec.hs. Builds a real 'Application' on a
-- fresh, temporary, file-backed SQLite db.
--
-- Deliberately no @:memory:@ here (unlike 'Db.Setup.withTestDb'): the
-- Api layer goes through 'Db.Pool', and @:memory:@ is its own empty
-- database per connection — with a pool of more than one connection,
-- requests could therefore sometimes see a "different" database. A
-- temp file is exactly what the pool uses in production too.
--
-- No cleanup of the pool/file after use: 'Test.Hspec.Wai.with' calls
-- this again per test for a fresh, isolated 'Application'; cleanly
-- shutting down the pool would have to tie its lifetime to that call
-- semantics (fragile), and this is a short-lived test process anyway —
-- the OS temp directory cleans itself up regardless.
module Api.Setup
  ( withTestApp
  ) where

import Api (application)
import Api.Monad (AppEnv (AppEnv))
import Db.Pool (createPool)
import Network.Wai (Application)
import System.Directory (getTemporaryDirectory)
import System.IO (hClose, openTempFile)

withTestApp :: IO Application
withTestApp = do
  dbPath <- freshTempDbPath
  pool <- createPool dbPath
  pure (application (AppEnv pool))

freshTempDbPath :: IO FilePath
freshTempDbPath = do
  tmpDir <- getTemporaryDirectory
  (path, handle) <- openTempFile tmpDir "bucktracker-api-test.db"
  hClose handle
  pure path
