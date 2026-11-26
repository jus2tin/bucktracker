-- | The combined Servant API and the WAI 'Application' that Warp runs.
module Api
  ( application
  ) where

import Control.Monad.Except (throwError)
import Lucid (Html)
import Network.Wai (Application)
import Servant
import Servant.HTML.Lucid (HTML)

import Api.Accounts (AccountsApi, accountsServer)
import Api.Categories (CategoriesApi, categoriesServer)
import Api.Monad (AppEnv, AppM, runAppM)

type RootApi =
  Get '[HTML] (Html ())
    :<|> AccountsApi
    :<|> CategoriesApi

rootApi :: Proxy RootApi
rootApi = Proxy

server :: ServerT RootApi AppM
server = rootHandler :<|> accountsServer :<|> categoriesServer

-- | "/" redirects to "/accounts" — there's no real dashboard yet (will
-- come with the budget page, see DECISIONS.md §4).
rootHandler :: AppM (Html ())
rootHandler = throwError err303 {errHeaders = [("Location", "/accounts")]}

application :: AppEnv -> Application
application env = serve rootApi (hoistServer rootApi (runAppM env) server)
