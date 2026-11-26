-- | Routes en handlers voor rekeningen: dun houden, alleen HTTP-vertaling
-- (CLAUDE.md "Architectuur") — de echte logica zit al in 'Db.Account'/
-- 'Domain.Account'.
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

-- | Veldnamen moeten overeenkomen met de @name@-attributen van
-- 'newAccountForm' hieronder — 'FromForm' parseert op veldnaam.
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
  pure (page "Rekeningen" (accountsContent Nothing accounts))

createAccountHandler :: NewAccountForm -> AppM (Html ())
createAccountHandler form = case accountTypeFromText (accountType form) of
  Nothing -> withError "Onbekend rekeningtype."
  Just ty -> do
    result <- withConn (\conn -> Db.insertAccount conn (name form) ty)
    case result of
      Left (EmptyName _) -> withError "Naam mag niet leeg zijn."
      Left _ -> withError "Kon rekening niet aanmaken."
      Right _ -> renderFragment Nothing
  where
    withError :: Text -> AppM (Html ())
    withError msg = renderFragment (Just msg)

archiveAccountHandler :: Int64 -> AppM (Html ())
archiveAccountHandler rawId = do
  withConn (\conn -> Db.archiveAccount conn (AccountId rawId))
  renderFragment Nothing

-- | Elke muterende handler rendert exact dit fragment terug: HTMX swapt
-- @#accounts-content@ (hx-swap="outerHTML"), dus de pagina ververst zonder
-- volledige navigatie.
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
    input_ [type_ "text", name_ "name", placeholder_ "Naam"]
    select_ [name_ "accountType"] (mapM_ accountTypeOption [minBound .. maxBound])
    button_ [type_ "submit"] "Toevoegen"

accountTypeOption :: AccountType -> Html ()
accountTypeOption ty = option_ [value_ (accountTypeToText ty)] (toHtml (accountTypeToText ty))

accountsTable :: [Account] -> Html ()
accountsTable accounts = table_ $ do
  thead_ (tr_ (mapM_ (th_ . toHtml) (["Naam", "Type", "Status", ""] :: [Text])))
  tbody_ (mapM_ accountRow accounts)

accountRow :: Account -> Html ()
accountRow acc = tr_ $ do
  td_ (toHtml (accName acc))
  td_ (toHtml (accountTypeToText (accType acc)))
  td_ (toHtml (statusText (isArchived acc)))
  td_ (archiveButton acc)
  where
    statusText archived = if archived then "Gearchiveerd" else "Actief" :: Text

archiveButton :: Account -> Html ()
archiveButton acc
  | isArchived acc = mempty
  | otherwise =
      button_
        [ hxPost_ ("/accounts/" <> accountIdText (accId acc) <> "/archive")
        , hxTarget_ "#accounts-content"
        , hxSwap_ "outerHTML"
        ]
        "Archiveer"

accountIdText :: AccountId -> Text
accountIdText (AccountId i) = Text.pack (show i)
