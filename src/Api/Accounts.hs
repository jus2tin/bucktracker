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
import Database.SQLite.Simple (Connection)
import GHC.Generics (Generic)
import Lucid
import Lucid.Base (makeAttribute)
import Servant
import Servant.HTML.Lucid (HTML)

import Api.Html
  ( errorBanner
  , hxConfirm_
  , hxPost_
  , hxSwap_
  , hxTarget_
  , pageOrFragment
  , successBanner
  , xData_
  , xModel_
  , xOn_
  , xText_
  )
import Api.Monad (AppM, withConn)
import Api.Money (centsToEuroText, parseSignedEuros)
import qualified Db.Account as Db
import qualified Db.Transaction as Db
import Db.Tx (withReadSnapshot)
import Domain.Account (Account (accId, accName, accType), isArchived)
import Domain.Budget (accountBalance, clearedBalance)
import Domain.Error (DomainError (EmptyName))
import Domain.Transaction (Transaction (txStatus))
import Domain.Types
  ( AccountId (AccountId)
  , AccountType
  , TransactionStatus (Reconciled)
  , accountTypeFromText
  , accountTypeToText
  , centsValue
  , zeroCents
  )
import Web.FormUrlEncoded (FromForm)

type AccountsApi =
  "accounts" :> Get '[HTML] (Html ())
    :<|> Header "HX-Request" Text :> "accounts" :> ReqBody '[FormUrlEncoded] NewAccountForm :> Post '[HTML] (Html ())
    :<|> Header "HX-Request" Text :> "accounts" :> Capture "id" Int64 :> "archive" :> Post '[HTML] (Html ())
    :<|> Header "HX-Request" Text :> "accounts" :> Capture "id" Int64 :> "unarchive" :> Post '[HTML] (Html ())
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
    :<|> unarchiveAccountHandler
    :<|> reconcileAccountHandler

-- | Exactly one pool checkout per request (Track B §1.4): 'renderFragment'
-- folds its own several reads into one 'withReadSnapshot' on the single
-- 'Connection' 'withConn' borrows here.
listAccountsHandler :: AppM (Html ())
listAccountsHandler = withConn $ \conn -> renderFragment conn Nothing Nothing Nothing

createAccountHandler :: Maybe Text -> NewAccountForm -> AppM (Html ())
createAccountHandler hx form = withConn $ \conn -> case accountTypeFromText (accountType form) of
  Nothing -> withError conn hx "Unknown account type."
  Just ty -> do
    result <- Db.insertAccount conn (name form) ty
    case result of
      Left (EmptyName _) -> withError conn hx "Name must not be empty."
      Left _ -> withError conn hx "Could not create account."
      Right _ -> renderFragment conn hx Nothing Nothing

-- | Blocks archiving an account that still has a non-zero balance, or
-- that still has any not-yet-'Reconciled' transaction even at a zero
-- balance (DECISIONS.md §11, AUDIT-04): archiving hides it from every
-- "new entry" picker and permanently hides 'reconcileCell', so an
-- account with offsetting Uncleared rows (e.g. +€100/-€100) would
-- otherwise lose its only path to ever reconciling those rows. A no-op
-- (not an error) on an unknown id, consistent with every other
-- archive/unarchive handler.
archiveAccountHandler :: Maybe Text -> Int64 -> AppM (Html ())
archiveAccountHandler hx rawId = withConn $ \conn -> do
  let aid = AccountId rawId
  txs <- Db.listTransactionsForAccount conn aid
  if accountBalance aid txs /= zeroCents
    then withError conn hx "Cannot archive an account with a non-zero balance."
    else
      if any ((/= Reconciled) . txStatus) txs
        then withError conn hx "Cannot archive an account with unreconciled transactions."
        else do
          Db.archiveAccount conn aid
          renderFragment conn hx Nothing Nothing

unarchiveAccountHandler :: Maybe Text -> Int64 -> AppM (Html ())
unarchiveAccountHandler hx rawId = withConn $ \conn -> do
  Db.unarchiveAccount conn (AccountId rawId)
  renderFragment conn hx Nothing Nothing

-- | The reconciliation workflow (DECISIONS.md §4/§3): compares
-- 'Domain.Budget.clearedBalance' (everything the register has marked
-- Cleared/Reconciled on this account, via the per-row "Clear" toggle on
-- the Transactions page) against the balance the user read off their
-- bank statement. On a match, the write locks in every Cleared
-- transaction as Reconciled; on a mismatch, nothing is written — the
-- user gets the two numbers back to go find the discrepancy themselves
-- (reconciliation is a pure comparison, not a type of its own, see
-- DECISIONS.md §3). The comparison and the write both happen inside
-- 'Db.reconcileAccountIfMatches', in one SQL transaction on one
-- connection (AUDIT-05): reading 'clearedBalance' and writing
-- 'Db.reconcileAccount' as two separate pool checkouts, as this used to
-- do, left a gap where a concurrently-cleared row could slip in between
-- them and get silently marked Reconciled without ever having been
-- compared against the statement.
reconcileAccountHandler :: Maybe Text -> Int64 -> ReconcileForm -> AppM (Html ())
reconcileAccountHandler hx rawId form = withConn $ \conn -> case parseSignedEuros (statementBalance form) of
  Nothing -> withError conn hx "Invalid statement balance."
  Just stmt -> do
    let aid = AccountId rawId
    accounts <- Db.listAccounts conn
    if not (any ((== aid) . accId) accounts)
      then withError conn hx "Unknown account."
      else do
        result <- Db.reconcileAccountIfMatches conn aid stmt
        case result of
          Right () -> renderFragment conn hx Nothing (Just "Account reconciled.")
          Left cleared ->
            withError
              conn
              hx
              ( "Doesn't match: your cleared transactions add up to "
                  <> centsToEuroText cleared
                  <> ", not "
                  <> centsToEuroText stmt
                  <> ". Nothing was changed — check for a missing, duplicate, or uncleared transaction."
              )

withError :: Connection -> Maybe Text -> Text -> IO (Html ())
withError conn hx msg = renderFragment conn hx (Just msg) Nothing

-- | Every handler renders back through this, on the one 'Connection'
-- it was already given. A plain (non-HTMX) request gets a full page
-- back — the progressive-enhancement fallback for when HTMX didn't
-- load — an HTMX request gets just the @#accounts-content@ fragment
-- it's about to swap in (hx-swap="outerHTML"); see
-- 'Api.Html.pageOrFragment'. Both reads share one 'withReadSnapshot'
-- (Track B §1.4), so the balance/status figures and the full
-- transaction list can never be a mismatched pair from two different
-- points in time.
renderFragment :: Connection -> Maybe Text -> Maybe Text -> Maybe Text -> IO (Html ())
renderFragment conn hx err successMsg = withReadSnapshot conn $ do
  accounts <- Db.listAccounts conn
  txs <- Db.listAllTransactions conn
  pure (pageOrFragment hx "Accounts" (accountsContent err successMsg accounts txs))

accountsContent :: Maybe Text -> Maybe Text -> [Account] -> [Transaction] -> Html ()
accountsContent err successMsg accounts txs = div_ [id_ "accounts-content"] $ do
  errorBanner err
  successBanner successMsg
  newAccountForm
  onboardingBanner accounts
  accountsTable accounts txs

-- | Shown instead of a bare, empty table the very first time Bucktracker
-- is opened (Track A Step 6) — a blank table with no accounts and no
-- explanation reads as broken, not as "add your first one here".
onboardingBanner :: [Account] -> Html ()
onboardingBanner [] = p_ "No accounts yet — add your checking account, savings, or cash above to get started."
onboardingBanner _  = mempty

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
  td_ (a_ [href_ ("/transactions?account=" <> accountIdText (accId acc))] (toHtml (accName acc)))
  td_ (toHtml (accountTypeToText (accType acc)))
  td_ [class_ "amount"] (toHtml (centsToEuroText (accountBalance (accId acc) txs)))
  td_ (toHtml (statusText (isArchived acc)))
  td_ (archiveToggleButton acc)
  td_ (reconcileCell txs acc)
  where
    statusText archived = if archived then "Archived" else "Active" :: Text

-- | One button that flips between "Archive" and "Unarchive" depending
-- on the account's current status (same toggle-label shape as
-- 'Api.Transactions.clearButton') — DECISIONS.md §11's "real unarchive
-- action", plus an @hx-confirm@ prompt before archiving (not before
-- un-archiving, which is always harmless) so one misclick doesn't
-- silently hide an account.
archiveToggleButton :: Account -> Html ()
archiveToggleButton acc
  | isArchived acc =
      let routePath = "/accounts/" <> accountIdText (accId acc) <> "/unarchive"
      in form_ [method_ "post", action_ routePath] $
           button_
             [type_ "submit", hxPost_ routePath, hxTarget_ "#accounts-content", hxSwap_ "outerHTML"]
             "Unarchive"
  | otherwise =
      let routePath = "/accounts/" <> accountIdText (accId acc) <> "/archive"
      in form_ [method_ "post", action_ routePath] $
           button_
             [ type_ "submit"
             , hxPost_ routePath
             , hxTarget_ "#accounts-content"
             , hxSwap_ "outerHTML"
             , hxConfirm_ "Archive this account?"
             ]
             "Archive"

-- | No reconcile control once an account is archived (DECISIONS.md
-- §11) — reconciling only ever matters for an account still receiving
-- new activity, and an archived account's balance is required to
-- already be zero (see 'archiveAccountHandler').
reconcileCell :: [Transaction] -> Account -> Html ()
reconcileCell txs acc
  | isArchived acc = mempty
  | otherwise = reconcileForm txs acc

-- | Compares against 'Domain.Budget.clearedBalance' server-side
-- (reconcileAccountHandler) — now signed (an overdrawn checking
-- account or a negative-balance liability can reconcile too, Architect
-- review S-2.2), with a live Alpine @reconcileCalc@ wrapper that shows
-- @Cleared − Statement = Difference@ as the user types, before they
-- even click "Reconcile" — purely a preview; the server-side
-- comparison in 'reconcileAccountHandler' is still what decides
-- whether anything actually gets written.
reconcileForm :: [Transaction] -> Account -> Html ()
reconcileForm txs acc =
  let routePath = "/accounts/" <> accountIdText (accId acc) <> "/reconcile"
      cleared = clearedBalance (accId acc) txs
  in form_
       [ method_ "post"
       , action_ routePath
       , hxPost_ routePath
       , hxTarget_ "#accounts-content"
       , hxSwap_ "outerHTML"
       , xData_ "reconcileCalc()"
       , dataClearedCents_ (Text.pack (show (centsValue cleared)))
       ]
       $ do
         input_
           [ type_ "text"
           , name_ "statementBalance"
           , placeholder_ "Statement balance"
           , xModel_ "statementBalance"
           , xOn_ "input" "recalc()"
           ]
         button_ [type_ "submit"] "Reconcile"
         p_ [xText_ "differenceLabel"] ""

-- | @data-cleared-cents@ — the account's current 'clearedBalance', in
-- integer cents, for 'reconcileForm'\'s Alpine component to read
-- without re-deriving it (and without doing its own currency math on
-- anything other than whatever the user is currently typing).
dataClearedCents_ :: Text -> Attribute
dataClearedCents_ = makeAttribute "data-cleared-cents"

accountIdText :: AccountId -> Text
accountIdText (AccountId i) = Text.pack (show i)
