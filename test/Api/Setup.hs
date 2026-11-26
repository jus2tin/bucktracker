-- | Test-helper, geen *Spec.hs. Bouwt een echte 'Application' op een
-- vers, tijdelijk, bestands-backed SQLite-db.
--
-- Bewust geen @:memory:@ hier (anders dan 'Db.Setup.withTestDb'): de
-- Api-laag gaat via 'Db.Pool', en @:memory:@ is per connectie een eigen
-- lege database — met een pool van meer dan één connectie zouden
-- requests dus soms een "andere" database zien. Een tijdelijk bestand is
-- precies wat de pool in productie ook gebruikt.
--
-- Geen cleanup van pool/bestand na gebruik: 'Test.Hspec.Wai.with' roept
-- dit per test opnieuw aan voor een verse, geïsoleerde 'Application'; de
-- pool netjes afsluiten zou zijn levensduur aan die call-semantiek moeten
-- koppelen (fragiel), en het is een kortlevend testproces — de OS-temp-map
-- ruimt zichzelf toch op.
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
