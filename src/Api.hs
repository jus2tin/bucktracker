-- | De samengestelde Servant-API en de WAI-'Application' die Warp draait.
module Api
  ( application
  ) where

import Control.Monad.Except (throwError)
import Lucid (Html)
import Network.Wai (Application)
import Servant
import Servant.HTML.Lucid (HTML)

import Api.Accounts (AccountsApi, accountsServer)
import Api.Monad (AppEnv, AppM, runAppM)

type RootApi =
  Get '[HTML] (Html ())
    :<|> AccountsApi

rootApi :: Proxy RootApi
rootApi = Proxy

server :: ServerT RootApi AppM
server = rootHandler :<|> accountsServer

-- | "/" stuurt door naar "/accounts" — er is nog geen echt dashboard
-- (volgt met de budgetpagina, zie DECISIONS.md §4).
rootHandler :: AppM (Html ())
rootHandler = throwError err303 {errHeaders = [("Location", "/accounts")]}

application :: AppEnv -> Application
application env = serve rootApi (hoistServer rootApi (runAppM env) server)
