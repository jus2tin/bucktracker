-- | The handler monad: 'ReaderT' 'AppEnv' over Servant's 'Handler' (see
-- CLAUDE.md "Error handling" and DECISIONS.md §2) — handlers can be
-- tested this way without a running server, by supplying your own
-- 'AppEnv' and calling 'runAppM'.
module Api.Monad
  ( AppEnv (..)
  , AppM
  , runAppM
  , withConn
  ) where

import Control.Monad.Except (MonadError)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Reader (MonadReader, ReaderT, asks, runReaderT)
import Data.Pool (Pool)
import Database.SQLite.Simple (Connection)
import qualified Db.Pool as Pool
import Servant (Handler, ServerError)

data AppEnv = AppEnv
  { appPool      :: Pool Connection
  , appStaticDir :: FilePath
    -- ^ Where the vendored, pinned static assets (Pico CSS, HTMX,
    -- Alpine.js, @app.js@) live on disk — resolved once at startup via
    -- @Paths_bucktracker.getDataDir@, the same mechanism already used
    -- for @migrations/@ (DECISIONS.md §7/§12). Served by 'Api.application'
    -- at @\/static\/*@.
  }

newtype AppM a = AppM (ReaderT AppEnv Handler a)
  deriving newtype (Functor, Applicative, Monad, MonadIO, MonadReader AppEnv, MonadError ServerError)

runAppM :: AppEnv -> AppM a -> Handler a
runAppM env (AppM action) = runReaderT action env

-- | Borrow a connection from the pool for the duration of @action@ (see
-- Db.Pool: repository functions always work with a plain 'Connection',
-- never with the 'Pool' itself).
withConn :: (Connection -> IO a) -> AppM a
withConn action = do
  pool <- asks appPool
  liftIO (Pool.withConnection pool action)
