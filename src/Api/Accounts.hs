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
import qualified Data.Text.Read as TextRead
import GHC.Generics (Generic)
import Lucid
import Servant
import Servant.HTML.Lucid (HTML)

import Api.Html (errorBanner, hxPost_, hxSwap_, hxTarget_, pageOrFragment, successBanner)
import Api.Monad (AppM, withConn)
import qualified Db.Account as Db
import qualified Db.Transaction as Db
import Domain.Account (Account (accId, accName, accType), isArchived)
import Domain.Budget (accountBalance, clearedBalance)
import Domain.Error (DomainError (EmptyName))
import Domain.Transaction (Transaction)
import Domain.Types
  ( AccountId (AccountId)
  , AccountType
  , Cents
  , accountTypeFromText
  , accountTypeToText
  , cents
  , centsValue
  )
import Web.FormUrlEncoded (FromForm)

type AccountsApi =
  "accounts" :> Get '[HTML] (Html ())
    :<|> Header "HX-Request" Text :> "accounts" :> ReqBody '[FormUrlEncoded] NewAccountForm :> Post '[HTML] (Html ())
    :<|> Header "HX-Request" Text :> "accounts" :> Capture "id" Int64 :> "archive" :> Post '[HTML] (Html ())
    :<|> Header "HX-Request" Text :> "accounts" :> Capture "id" Int64 :> "reconcile" :> ReqBody '[FormUrlEncoded] ReconcileForm :> Post '[HTML] (Html ())

-- | Field names must match the @name@ attributes of 'newAccountForm'
-- below — 'FromForm' parses by field name.
data NewAccountForm = NewAccountForm
  { name        :: Text
  , accountType :: Text
  }
  deriving stock (Generic)
  deriving anyclass (FromForm)

-- | Field name must match the @name@ attribute of 'reconcileForm' below.
newtype ReconcileForm = ReconcileForm
  { statementBalance :: Text
  }
  deriving stock (Generic)
  deriving anyclass (FromForm)

accountsServer :: ServerT AccountsApi AppM
accountsServer =
  listAccountsHandler
    :<|> createAccountHandler
    :<|> archiveAccountHandler
    :<|> reconcileAccountHandler

listAccountsHandler :: AppM (Html ())
listAccountsHandler = renderFragment Nothing Nothing Nothing

createAccountHandler :: Maybe Text -> NewAccountForm -> AppM (Html ())
createAccountHandler hx form = case accountTypeFromText (accountType form) of
  Nothing -> withError hx "Unknown account type."
  Just ty -> do
    result <- withConn (\conn -> Db.insertAccount conn (name form) ty)
    case result of
      Left (EmptyName _) -> withError hx "Name must not be empty."
      Left _ -> withError hx "Could not create account."
      Right _ -> renderFragment hx Nothing Nothing

archiveAccountHandler :: Maybe Text -> Int64 -> AppM (Html ())
archiveAccountHandler hx rawId = do
  withConn (\conn -> Db.archiveAccount conn (AccountId rawId))
  renderFragment hx Nothing Nothing

-- | The reconciliation workflow (DECISIONS.md §4/§3): compares
-- 'Domain.Budget.clearedBalance' (everything the register has marked
-- Cleared/Reconciled on this account, via the per-row "Clear" toggle on
-- the Transactions page) against the balance the user read off their
-- bank statement. On a match, 'Db.Transaction.reconcileAccount' locks
-- in every Cleared transaction as Reconciled; on a mismatch, nothing is
-- written — the user gets the two numbers back to go find the
-- discrepancy themselves (reconciliation is a pure comparison, not a
-- type of its own, see DECISIONS.md §3).
reconcileAccountHandler :: Maybe Text -> Int64 -> ReconcileForm -> AppM (Html ())
reconcileAccountHandler hx rawId form = case parseEuros (statementBalance form) of
  Nothing -> withError hx "Invalid statement balance."
  Just stmt -> do
    let aid = AccountId rawId
    accounts <- withConn Db.listAccounts
    if not (any ((== aid) . accId) accounts)
      then withError hx "Unknown account."
      else do
        txs <- withConn (\conn -> Db.listTransactionsForAccount conn aid)
        let cleared = clearedBalance aid txs
        if cleared == stmt
          then do
            withConn (\conn -> Db.reconcileAccount conn aid)
            renderFragment hx Nothing (Just "Account reconciled.")
          else
            withError
              hx
              ( "Doesn't match: your cleared transactions add up to "
                  <> centsToEuroText cleared
                  <> ", not "
                  <> centsToEuroText stmt
                  <> ". Nothing was changed — check for a missing, duplicate, or uncleared transaction."
              )

withError :: Maybe Text -> Text -> AppM (Html ())
withError hx msg = renderFragment hx (Just msg) Nothing

-- | Every mutating handler renders back through this. A plain
-- (non-HTMX) request gets a full page back — the progressive-
-- enhancement fallback for when HTMX didn't load — an HTMX request
-- gets just the @#accounts-content@ fragment it's about to swap in
-- (hx-swap="outerHTML"); see 'Api.Html.pageOrFragment'.
renderFragment :: Maybe Text -> Maybe Text -> Maybe Text -> AppM (Html ())
renderFragment hx err successMsg = do
  accounts <- withConn Db.listAccounts
  txs <- withConn Db.listAllTransactions
  pure (pageOrFragment hx "Accounts" (accountsContent err successMsg accounts txs))

accountsContent :: Maybe Text -> Maybe Text -> [Account] -> [Transaction] -> Html ()
accountsContent err successMsg accounts txs = div_ [id_ "accounts-content"] $ do
  errorBanner err
  successBanner successMsg
  newAccountForm
  accountsTable accounts txs

newAccountForm :: Html ()
newAccountForm =
  form_
    [method_ "post", action_ "/accounts", hxPost_ "/accounts", hxTarget_ "#accounts-content", hxSwap_ "outerHTML"]
    $ do
      input_ [type_ "text", name_ "name", placeholder_ "Name"]
      select_ [name_ "accountType"] (mapM_ accountTypeOption [minBound .. maxBound])
      button_ [type_ "submit"] "Add"

accountTypeOption :: AccountType -> Html ()
accountTypeOption ty = option_ [value_ (accountTypeToText ty)] (toHtml (accountTypeToText ty))

accountsTable :: [Account] -> [Transaction] -> Html ()
accountsTable accounts txs = table_ $ do
  thead_ (tr_ (mapM_ (th_ . toHtml) (["Name", "Type", "Balance", "Status", "", ""] :: [Text])))
  tbody_ (mapM_ (accountRow txs) accounts)

accountRow :: [Transaction] -> Account -> Html ()
accountRow txs acc = tr_ $ do
  td_ (toHtml (accName acc))
  td_ (toHtml (accountTypeToText (accType acc)))
  td_ [class_ "amount"] (toHtml (centsToEuroText (accountBalance (accId acc) txs)))
  td_ (toHtml (statusText (isArchived acc)))
  td_ (archiveButton acc)
  td_ (reconcileForm acc)
  where
    statusText archived = if archived then "Archived" else "Active" :: Text

archiveButton :: Account -> Html ()
archiveButton acc
  | isArchived acc = mempty
  | otherwise =
      let routePath = "/accounts/" <> accountIdText (accId acc) <> "/archive"
      in form_ [method_ "post", action_ routePath] $
           button_
             [type_ "submit", hxPost_ routePath, hxTarget_ "#accounts-content", hxSwap_ "outerHTML"]
             "Archive"

-- | Compares against 'Domain.Budget.clearedBalance' server-side
-- (reconcileAccountHandler) — this is just the one-field input for the
-- number the user read off their bank statement.
reconcileForm :: Account -> Html ()
reconcileForm acc =
  let routePath = "/accounts/" <> accountIdText (accId acc) <> "/reconcile"
  in form_ [method_ "post", action_ routePath, hxPost_ routePath, hxTarget_ "#accounts-content", hxSwap_ "outerHTML"] $ do
       input_ [type_ "number", step_ "0.01", min_ "0", name_ "statementBalance", placeholder_ "Statement balance"]
       button_ [type_ "submit"] "Reconcile"

accountIdText :: AccountId -> Text
accountIdText (AccountId i) = Text.pack (show i)

centsToEuroText :: Cents -> Text
centsToEuroText amt =
  sign <> Text.pack (show whole) <> "." <> pad2 frac
  where
    raw = centsValue amt
    sign = if raw < 0 then "-" else ""
    absValue = abs raw
    whole = absValue `div` 100
    frac = absValue `mod` 100
    pad2 n =
      let s = Text.pack (show n)
      in if Text.length s < 2 then "0" <> s else s

parseInt64 :: Text -> Maybe Int64
parseInt64 t = case TextRead.decimal t of
  Right (n, rest) | Text.null rest -> Just n
  _                                -> Nothing

-- | Parses a non-negative decimal euro amount (e.g. @"12.34"@ or
-- @"12"@) into whole cents, total and without 'Prelude.read'.
parseEuros :: Text -> Maybe Cents
parseEuros raw = case Text.splitOn "." (Text.strip raw) of
  [wholePart] -> centsFromParts wholePart "00"
  [wholePart, fracPart]
    | Text.length fracPart == 1 -> centsFromParts wholePart (fracPart <> "0")
    | Text.length fracPart == 2 -> centsFromParts wholePart fracPart
  _ -> Nothing

centsFromParts :: Text -> Text -> Maybe Cents
centsFromParts wholePart fracPart
  | Text.null wholePart = Nothing
  | otherwise = do
      whole <- parseInt64 wholePart
      frac <- parseInt64 fracPart
      Just (cents (whole * 100 + frac))
