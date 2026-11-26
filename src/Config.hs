-- | Application configuration, loaded from environment variables.
--
-- See DECISIONS.md §7: 'envparse' for structured validation/error
-- messages, with a platform-independent default DB path via the XDG
-- data directory (on Windows %APPDATA%\bucktracker\, on Linux usually
-- ~/.local/share/bucktracker/).
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

-- | Reads BUCKTRACKER_PORT and BUCKTRACKER_DB_PATH; prints usable help
-- and stops the process if a variable is missing/invalid (the behavior
-- of 'Env.parse'). Both have a default, so in practice the app starts
-- without anything needing to be set.
loadConfig :: IO Config
loadConfig = do
  dbPathDefault <- defaultDbPath
  Env.parse (header "bucktracker") $
    Config
      <$> var auto "BUCKTRACKER_PORT" (def 8080 <> help "HTTP port for the Warp server")
      <*> var str "BUCKTRACKER_DB_PATH" (def dbPathDefault <> help "Path to the SQLite database file")

defaultDbPath :: IO FilePath
defaultDbPath = do
  dataDir <- getXdgDirectory XdgData "bucktracker"
  pure (dataDir </> "bucktracker.db")
