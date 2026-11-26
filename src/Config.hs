-- | Applicatieconfiguratie, geladen uit environment-variabelen.
--
-- Zie DECISIONS.md §7: 'envparse' voor gestructureerde validatie/
-- foutmeldingen, met een platform-onafhankelijk standaard DB-pad via de
-- XDG-datadirectory (op Windows %APPDATA%\bucktracker\, op Linux
-- doorgaans ~/.local/share/bucktracker/).
module Config
  ( Config (..)
  , loadConfig
  ) where

import Env
import System.Directory (XdgDirectory (XdgData), getXdgDirectory)
import System.FilePath ((</>))

data Config = Config
  { configPort   :: Int
  , configDbPath :: FilePath
  } deriving stock (Eq, Show)

-- | Leest BUCKTRACKER_PORT en BUCKTRACKER_DB_PATH; print bruikbare hulp en
-- stopt het proces als een variabele ontbreekt/ongeldig is (het gedrag van
-- 'Env.parse'). Beide hebben een default, dus in de praktijk start de app
-- zonder dat er iets gezet moet worden.
loadConfig :: IO Config
loadConfig = do
  dbPathDefault <- defaultDbPath
  Env.parse (header "bucktracker") $
    Config
      <$> var auto "BUCKTRACKER_PORT" (def 8080 <> help "HTTP-poort voor de Warp-server")
      <*> var str "BUCKTRACKER_DB_PATH" (def dbPathDefault <> help "Pad naar het SQLite-databasebestand")

defaultDbPath :: IO FilePath
defaultDbPath = do
  dataDir <- getXdgDirectory XdgData "bucktracker"
  pure (dataDir </> "bucktracker.db")
