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
import Api.Budget (BudgetApi, budgetServer)
import Api.Categories (CategoriesApi, categoriesServer)
import Api.Monad (AppEnv, AppM, runAppM)
import Api.Transactions (TransactionsApi, transactionsServer)

type RootApi =
  Get '[HTML] (Html ())
    :<|> AccountsApi
    :<|> CategoriesApi
    :<|> TransactionsApi
    :<|> BudgetApi

rootApi :: Proxy RootApi
rootApi = Proxy

server :: ServerT RootApi AppM
server =
  rootHandler
    :<|> accountsServer
    :<|> categoriesServer
    :<|> transactionsServer
    :<|> budgetServer

-- | "/" redirects to "/budget", the closest thing to a dashboard today.
rootHandler :: AppM (Html ())
rootHandler = throwError err303 {errHeaders = [("Location", "/budget")]}

application :: AppEnv -> Application
application env = serve rootApi (hoistServer rootApi (runAppM env) server)
