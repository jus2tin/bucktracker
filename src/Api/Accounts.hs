-- | Routes and handlers for accounts: keep thin, HTTP translation only
-- (CLAUDE.md "Architecture") — the real logic already lives in
-- 'Db.Account'/'Domain.Account'.
module Api.Accounts
  ( AccountsApi
  , accountsServer
  ) where

import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as Text
import GHC.Generics (Generic)
import Lucid
import Servant
import Servant.HTML.Lucid (HTML)

import Api.Html (errorBanner, hxPost_, hxSwap_, hxTarget_, page)
import Api.Monad (AppM, withConn)
import qualified Db.Account as Db
import Domain.Account (Account (accId, accName, accType), isArchived)
import Domain.Error (DomainError (EmptyName))
import Domain.Types
  ( AccountId (AccountId)
  , AccountType
  , accountTypeFromText
  , accountTypeToText
  )
import Web.FormUrlEncoded (FromForm)

type AccountsApi =
  "accounts" :> Get '[HTML] (Html ())
    :<|> "accounts" :> ReqBody '[FormUrlEncoded] NewAccountForm :> Post '[HTML] (Html ())
    :<|> "accounts" :> Capture "id" Int64 :> "archive" :> Post '[HTML] (Html ())

-- | Field names must match the @name@ attributes of 'newAccountForm'
-- below — 'FromForm' parses by field name.
data NewAccountForm = NewAccountForm
  { name        :: Text
  , accountType :: Text
  }
  deriving stock (Generic)
  deriving anyclass (FromForm)

accountsServer :: ServerT AccountsApi AppM
accountsServer = listAccountsHandler :<|> createAccountHandler :<|> archiveAccountHandler

listAccountsHandler :: AppM (Html ())
listAccountsHandler = do
  accounts <- withConn Db.listAccounts
  pure (page "Accounts" (accountsContent Nothing accounts))

createAccountHandler :: NewAccountForm -> AppM (Html ())
createAccountHandler form = case accountTypeFromText (accountType form) of
  Nothing -> withError "Unknown account type."
  Just ty -> do
    result <- withConn (\conn -> Db.insertAccount conn (name form) ty)
    case result of
      Left (EmptyName _) -> withError "Name must not be empty."
      Left _ -> withError "Could not create account."
      Right _ -> renderFragment Nothing
  where
    withError :: Text -> AppM (Html ())
    withError msg = renderFragment (Just msg)

archiveAccountHandler :: Int64 -> AppM (Html ())
archiveAccountHandler rawId = do
  withConn (\conn -> Db.archiveAccount conn (AccountId rawId))
  renderFragment Nothing

-- | Every mutating handler renders back exactly this fragment: HTMX
-- swaps @#accounts-content@ (hx-swap="outerHTML"), so the page updates
-- without a full navigation.
renderFragment :: Maybe Text -> AppM (Html ())
renderFragment err = do
  accounts <- withConn Db.listAccounts
  pure (accountsContent err accounts)

accountsContent :: Maybe Text -> [Account] -> Html ()
accountsContent err accounts = div_ [id_ "accounts-content"] $ do
  errorBanner err
  newAccountForm
  accountsTable accounts

newAccountForm :: Html ()
newAccountForm =
  form_ [hxPost_ "/accounts", hxTarget_ "#accounts-content", hxSwap_ "outerHTML"] $ do
    input_ [type_ "text", name_ "name", placeholder_ "Name"]
    select_ [name_ "accountType"] (mapM_ accountTypeOption [minBound .. maxBound])
    button_ [type_ "submit"] "Add"

accountTypeOption :: AccountType -> Html ()
accountTypeOption ty = option_ [value_ (accountTypeToText ty)] (toHtml (accountTypeToText ty))

accountsTable :: [Account] -> Html ()
accountsTable accounts = table_ $ do
  thead_ (tr_ (mapM_ (th_ . toHtml) (["Name", "Type", "Status", ""] :: [Text])))
  tbody_ (mapM_ accountRow accounts)

accountRow :: Account -> Html ()
accountRow acc = tr_ $ do
  td_ (toHtml (accName acc))
  td_ (toHtml (accountTypeToText (accType acc)))
  td_ (toHtml (statusText (isArchived acc)))
  td_ (archiveButton acc)
  where
    statusText archived = if archived then "Archived" else "Active" :: Text

archiveButton :: Account -> Html ()
archiveButton acc
  | isArchived acc = mempty
  | otherwise =
      button_
        [ hxPost_ ("/accounts/" <> accountIdText (accId acc) <> "/archive")
        , hxTarget_ "#accounts-content"
        , hxSwap_ "outerHTML"
        ]
        "Archive"

accountIdText :: AccountId -> Text
accountIdText (AccountId i) = Text.pack (show i)
