-- | De handler-monad: 'ReaderT' 'AppEnv' over Servant's 'Handler' (zie
-- CLAUDE.md "Error handling" en DECISIONS.md §2) — handlers kunnen zo
-- zonder een draaiende server getest worden door zelf een 'AppEnv' te
-- geven en 'runAppM' aan te roepen.
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

newtype AppEnv = AppEnv
  { appPool :: Pool Connection
  }

newtype AppM a = AppM (ReaderT AppEnv Handler a)
  deriving newtype (Functor, Applicative, Monad, MonadIO, MonadReader AppEnv, MonadError ServerError)

runAppM :: AppEnv -> AppM a -> Handler a
runAppM env (AppM action) = runReaderT action env

-- | Leen een connectie uit de pool voor de duur van @action@ (zie
-- Db.Pool: repository-functies werken altijd met een losse 'Connection',
-- nooit met de 'Pool' zelf).
withConn :: (Connection -> IO a) -> AppM a
withConn action = do
  pool <- asks appPool
  liftIO (Pool.withConnection pool action)
