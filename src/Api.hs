-- | The combined Servant API and the WAI 'Application' that Warp runs.
module Api
  ( application
  ) where

import Control.Monad.Except (throwError)
import Lucid (Html)
import Network.Wai.Application.Static (defaultWebAppSettings, ssMaxAge)
import Servant
import Servant.HTML.Lucid (HTML)
import WaiAppStatic.Types (MaxAge (NoMaxAge))

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
--
-- Deliberately 'serveDirectoryWith' with 'NoMaxAge', not the
-- 'serveDirectoryWebApp' default (a one-year @Cache-Control: max-age@)
-- — these files have no content hash in their names, and change every
-- time a Track A step touches @static/app.js@; a year-long browser
-- cache silently kept serving a stale script past several rebuilds
-- during Step 4's own live-browser verification (ARCHITECTURE.md
-- "Static assets").
server :: AppEnv -> ServerT RootApi AppM
server env =
  rootHandler
    :<|> accountsServer
    :<|> categoriesServer
    :<|> transactionsServer
    :<|> budgetServer
    :<|> serveDirectoryWith (defaultWebAppSettings (appStaticDir env)) {ssMaxAge = NoMaxAge}

-- | "/" redirects to "/budget", the closest thing to a dashboard today.
rootHandler :: AppM (Html ())
rootHandler = throwError err303 {errHeaders = [("Location", "/budget")]}

application :: AppEnv -> Application
application env = serve rootApi (hoistServer rootApi (runAppM env) (server env))
