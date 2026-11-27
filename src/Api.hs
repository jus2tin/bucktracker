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
import Api.Monad (AppEnv (appStaticDir), AppM, runAppM)
import Api.Transactions (TransactionsApi, transactionsServer)

type RootApi =
  Get '[HTML] (Html ())
    :<|> AccountsApi
    :<|> CategoriesApi
    :<|> TransactionsApi
    :<|> BudgetApi
    :<|> "static" :> Raw

rootApi :: Proxy RootApi
rootApi = Proxy

-- | The @"static" :> Raw@ branch needs 'appStaticDir' from the
-- 'AppEnv', so unlike the other (env-independent) sub-servers, this one
-- has to be built per-request-environment rather than once as a plain
-- top-level value.
server :: AppEnv -> ServerT RootApi AppM
server env =
  rootHandler
    :<|> accountsServer
    :<|> categoriesServer
    :<|> transactionsServer
    :<|> budgetServer
    :<|> serveDirectoryWebApp (appStaticDir env)

-- | "/" redirects to "/budget", the closest thing to a dashboard today.
rootHandler :: AppM (Html ())
rootHandler = throwError err303 {errHeaders = [("Location", "/budget")]}

application :: AppEnv -> Application
application env = serve rootApi (hoistServer rootApi (runAppM env) (server env))
