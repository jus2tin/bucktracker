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
  , postHtmlFormHx
  ) where

import Api (application)
import Api.Monad (AppEnv (AppEnv))
import Data.Bifunctor (bimap)
import qualified Data.ByteString.Char8 as BS8
import qualified Data.ByteString.Lazy as LBS
import Db.Pool (createPool)
import Network.HTTP.Types (hContentType, methodPost)
import Network.HTTP.Types.URI (renderSimpleQuery)
import Network.Wai (Application)
import Network.Wai.Test (SResponse)
import Paths_bucktracker (getDataDir)
import System.Directory (getTemporaryDirectory)
import System.FilePath ((</>))
import System.IO (hClose, openTempFile)
import Test.Hspec.Wai (WaiSession, request)

withTestApp :: IO Application
withTestApp = do
  dbPath <- freshTempDbPath
  pool <- createPool dbPath
  staticDir <- (</> "static") <$> getDataDir
  pure (application (AppEnv pool staticDir))

freshTempDbPath :: IO FilePath
freshTempDbPath = do
  tmpDir <- getTemporaryDirectory
  (path, handle) <- openTempFile tmpDir "bucktracker-api-test.db"
  hClose handle
  pure path

-- | Like 'Test.Hspec.Wai.postHtmlForm', but also sends
-- @HX-Request: true@ — simulates a real HTMX-driven POST, as opposed
-- to a plain browser form submission (the progressive-enhancement
-- fallback for when HTMX didn't load). Use this to assert the two
-- cases render differently: a bare @#...-content@ fragment here, a
-- full 'Api.Html.page' when the header is absent (see
-- 'Api.Html.pageOrFragment' — the S-1 fix).
postHtmlFormHx :: BS8.ByteString -> [(String, String)] -> WaiSession st SResponse
postHtmlFormHx path formParams =
  request methodPost path [(hContentType, "application/x-www-form-urlencoded"), ("HX-Request", "true")] body
  where
    body = LBS.fromStrict (renderSimpleQuery False (map (bimap BS8.pack BS8.pack) formParams))
