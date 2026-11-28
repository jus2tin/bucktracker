-- | Routes and handlers for transactions: keep thin, HTTP translation
-- only (CLAUDE.md "Architecture") — the real logic already lives in
-- 'Db.Transaction'/'Domain.Transaction'.
--
-- The spending form supports a genuine arbitrary-length split
-- (@1..N@ lines — already supported end-to-end by
-- 'Db.Transaction.insertSpending'/'Domain.Transaction', just not
-- reachable from the UI until now): 'NewSpendingForm' has a manual
-- 'FromForm' instance collecting every @lineCategoryId@/@lineAmount@
-- pair via 'lookupAll' rather than deriving fixed-name fields, and the
-- page adds/removes rows client-side (@static/app.js@'s @splitEditor@)
-- without a server round-trip. A line's amount is *signed*: a positive
-- amount is the usual expense portion, a negative one is a refund/
-- credit against that category (Architect review S-2.3) — the same
-- 'negateCents' that turns a typed @40.00@ into a stored @-€40@ turns a
-- typed @-15.00@ into a stored @+€15@, so refunds needed no change to
-- that convention, only to the parser accepting a sign at all.
--
-- 'NewInflowForm's amount is signed too (negative = an opening-balance
-- correction; still rejects exactly zero, Architect review S-2.4); a
-- transfer's amount stays strictly positive — the direction is already
-- chosen by which account is "from" and which is "to".
--
-- The register shows whichever month @?month=YYYY-MM@ names (default:
-- today's *local* calendar month — see 'Api.Monad.localToday', Track A
-- Step 5, S-4), optionally filtered to one account via @?account=<id>@.
-- A mutating action (create/edit/delete/clear) always returns to the
-- default view (today's month, no filter) rather than threading the
-- viewed month/filter back through every form — a deliberate v0.1
-- simplification: creating a transaction while browsing March and
-- landing back on the current month afterward is a minor rough edge,
-- not a correctness issue, and avoids two more hidden fields on every
-- one of the six forms on this page.
--
-- Archived accounts/categories (Track A Step 6, DECISIONS.md §11) are
-- rejected server-side on every *create* ('withValidInflow'\/
-- 'withValidSpending'\/'withValidTransfer' hand their fetched
-- @[Account]@\/@[Category]@ to the caller precisely so each create
-- handler can add that check on top) but deliberately *not* on an edit
-- of a transaction that's already on one — the account/category picker
-- a create form offers only ever lists active (and, for the spending
-- form, on-budget-only) entities to begin with, so this is defense in
-- depth for a direct POST, not something reachable through the UI. An
-- edit form, by contrast, still needs to show the transaction's
-- *current* account/category even if it's since been archived or (for
-- spending) is the "wrong" budget type — 'accountChoices'\/
-- 'categoryChoices' append that one entity back on if the active-only
-- filter would otherwise have dropped it, so a @\<select\>@ never
-- silently loses its selected option and reassigns the transaction on
-- save.
module Api.Transactions
  ( TransactionsApi
  , transactionsServer
  ) where

import Data.Int (Int64)
import Data.List (find)
import Data.List.NonEmpty (NonEmpty ((:|)), toList)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Read as TextRead
import Data.Time (Day, fromGregorianValid)
import GHC.Generics (Generic)
import Lucid
import Servant
import Servant.HTML.Lucid (HTML)

import Api.Html
  ( errorBanner
  , hxConfirm_
  , hxPost_
  , hxSwap_
  , hxTarget_
  , pageOrFragment
  , xData_
  , xModel_
  , xOn_
  , xRef_
  , xText_
  )
import Api.Monad (AppM, localToday, resolveViewedMonth, withConn)
import Api.Money (centsToEuroText, parseNonZeroSignedEuros, parsePositiveEuros)
import qualified Db.Account as Db
import qualified Db.Category as Db
import qualified Db.Transaction as Db
import Domain.Account (Account (accId, accName), isArchived, isOnBudget)
import Domain.Category (Category (catId, catName), isArchivedCategory)
import Domain.Error (DomainError (..))
import Domain.Transaction
  ( Categorization (Categorized, Inflow, TransferLeg)
  , Transaction (txAccount, txCategorization, txDate, txId, txPayee, txStatus)
  , TransactionLine (TransactionLine, tlAmount, tlCategory)
  , transactionAmount
  )
import Domain.Types
  ( AccountId (AccountId)
  , CategoryId (CategoryId)
  , Cents
  , TransactionId (TransactionId)
  , TransactionStatus (Reconciled, Uncleared)
  , YearMonth
  , dayToYearMonth
  , negateCents
  , nextYearMonth
  , prevYearMonth
  , transactionStatusToText
  , yearMonthToText
  , zeroCents
  )
import Web.FormUrlEncoded (Form, FromForm (fromForm), lookupAll, parseUnique)

type TransactionsApi =
  "transactions" :> QueryParam "month" Text :> QueryParam "account" Text :> Get '[HTML] (Html ())
    :<|> Header "HX-Request" Text :> "transactions" :> "inflow" :> ReqBody '[FormUrlEncoded] NewInflowForm :> Post '[HTML] (Html ())
    :<|> Header "HX-Request" Text :> "transactions" :> "spending" :> ReqBody '[FormUrlEncoded] NewSpendingForm :> Post '[HTML] (Html ())
    :<|> Header "HX-Request" Text :> "transactions" :> "transfer" :> ReqBody '[FormUrlEncoded] NewTransferForm :> Post '[HTML] (Html ())
    :<|> Header "HX-Request" Text :> "transactions" :> Capture "id" Int64 :> "clear" :> Post '[HTML] (Html ())
    :<|> Header "HX-Request" Text :> "transactions" :> Capture "id" Int64 :> "delete" :> Post '[HTML] (Html ())
    :<|> Header "HX-Request" Text :> "transactions" :> Capture "id" Int64 :> "edit-inflow" :> ReqBody '[FormUrlEncoded] NewInflowForm :> Post '[HTML] (Html ())
    :<|> Header "HX-Request" Text :> "transactions" :> Capture "id" Int64 :> "edit-spending" :> ReqBody '[FormUrlEncoded] NewSpendingForm :> Post '[HTML] (Html ())
    :<|> Header "HX-Request" Text :> "transactions" :> Capture "id" Int64 :> "edit-transfer" :> ReqBody '[FormUrlEncoded] NewTransferForm :> Post '[HTML] (Html ())

-- | Each form's fields are prefixed so the three forms on one page
-- never collide on a shared @name@ attribute (they share the page, not
-- a record) — 'FromForm' parses by field name.
data NewInflowForm = NewInflowForm
  { inflowAccountId :: Text
  , inflowDate      :: Text
  , inflowPayee     :: Text
  , inflowAmount    :: Text
  }
  deriving stock (Generic)
  deriving anyclass (FromForm)

-- | A manual 'FromForm' instance instead of 'Generic' deriving:
-- @lineCategoryId@/@lineAmount@ each repeat once per split line
-- ('lookupAll' collects every value under that key, in submission
-- order), rather than the fixed @spendingCategoryIdN@/@spendingAmountN@
-- field names the old 3-slot form used. Pairing them back up by
-- position (see 'parseSplitLines') relies on the page always emitting
-- a line's two inputs together, which @splitLineHtml@ does.
data NewSpendingForm = NewSpendingForm
  { spendingAccountId :: Text
  , spendingDate      :: Text
  , spendingPayee     :: Text
  , spendingLineCategoryIds :: [Text]
  , spendingLineAmounts     :: [Text]
  }

instance FromForm NewSpendingForm where
  fromForm :: Form -> Either Text NewSpendingForm
  fromForm f =
    NewSpendingForm
      <$> parseUnique "spendingAccountId" f
      <*> parseUnique "spendingDate" f
      <*> parseUnique "spendingPayee" f
      <*> pure (lookupAll "lineCategoryId" f)
      <*> pure (lookupAll "lineAmount" f)

data NewTransferForm = NewTransferForm
  { transferFromAccountId :: Text
  , transferToAccountId   :: Text
  , transferDate          :: Text
  , transferAmount        :: Text
  }
  deriving stock (Generic)
  deriving anyclass (FromForm)

transactionsServer :: ServerT TransactionsApi AppM
transactionsServer =
  listTransactionsHandler
    :<|> createInflowHandler
    :<|> createSpendingHandler
    :<|> createTransferHandler
    :<|> toggleClearedHandler
    :<|> deleteTransactionHandler
    :<|> editInflowHandler
    :<|> editSpendingHandler
    :<|> editTransferHandler

listTransactionsHandler :: Maybe Text -> Maybe Text -> AppM (Html ())
listTransactionsHandler monthParam accountParam = do
  ym <- resolveViewedMonth monthParam
  let accountFilter = accountParam >>= parseAccountFilterText
  renderFragment Nothing ym accountFilter Nothing

-- | @""@ (an absent @?account=@, or the hidden "clear filter" link's
-- empty value) means "no filter" — a bad id is treated the same way,
-- not as an error: this only ever narrows what's already shown, so
-- there's nothing to validate strictly against.
parseAccountFilterText :: Text -> Maybe AccountId
parseAccountFilterText t
  | Text.null (Text.strip t) = Nothing
  | otherwise = parseAccountId t

-- | Parses and validates an inflow form's fields, then hands them
-- (along with the accounts just fetched to validate @aid@) to @go@ —
-- shared by 'createInflowHandler' and 'editInflowHandler', which
-- otherwise differ only in calling 'Db.insertInflow' or
-- 'Db.updateInflow', and in whether archived accounts are rejected (see
-- the module header).
withValidInflow
  :: Maybe Text -> NewInflowForm -> ([Account] -> AccountId -> Day -> Text -> Cents -> AppM (Html ())) -> AppM (Html ())
withValidInflow hx form go = case parseAccountId (inflowAccountId form) of
  Nothing -> withError hx "Unknown account."
  Just aid -> case parseIsoDate (inflowDate form) of
    Nothing -> withError hx "Invalid date."
    Just day -> case parseNonZeroSignedEuros (inflowAmount form) of
      Nothing -> withError hx "Invalid amount."
      Just amt -> do
        accounts <- withConn Db.listAccounts
        if not (any ((== aid) . accId) accounts)
          then withError hx "Unknown account."
          else go accounts aid day (inflowPayee form) amt

createInflowHandler :: Maybe Text -> NewInflowForm -> AppM (Html ())
createInflowHandler hx form = withValidInflow hx form $ \accounts aid day payee amt ->
  case find ((== aid) . accId) accounts of
    Just acc | isArchived acc -> withError hx "Cannot add a transaction to an archived account."
    _ -> do
      _ <- withConn (\conn -> Db.insertInflow conn aid day payee defaultStatus amt Nothing)
      renderDefault hx

editInflowHandler :: Maybe Text -> Int64 -> NewInflowForm -> AppM (Html ())
editInflowHandler hx rawId form = withValidInflow hx form $ \_accounts aid day payee amt -> do
  result <- withConn (\conn -> Db.updateInflow conn (TransactionId rawId) aid day payee amt)
  case result of
    Left CannotModifyReconciledTransaction -> withError hx "Cannot edit a reconciled transaction."
    Left _ -> withError hx "Could not update transaction."
    Right _ -> renderDefault hx

-- | Parses and validates a spending (split) form's fields, then hands
-- them (along with the accounts/categories just fetched to validate
-- them) to @go@ — shared by 'createSpendingHandler' and
-- 'editSpendingHandler', which otherwise differ as described in the
-- module header.
withValidSpending
  :: Maybe Text
  -> NewSpendingForm
  -> ([Account] -> [Category] -> AccountId -> Day -> Text -> NonEmpty TransactionLine -> AppM (Html ()))
  -> AppM (Html ())
withValidSpending hx form go = case parseAccountId (spendingAccountId form) of
  Nothing -> withError hx "Unknown account."
  Just aid -> case parseIsoDate (spendingDate form) of
    Nothing -> withError hx "Invalid date."
    Just day ->
      case parseSplitLines (zip (spendingLineCategoryIds form) (spendingLineAmounts form)) of
        Left err -> withError hx err
        Right [] -> withError hx "A split needs at least one line."
        Right (line1 : restLines) -> do
          let lines' = line1 :| restLines
          accounts <- withConn Db.listAccounts
          categories <- withConn Db.listCategories
          if not (any ((== aid) . accId) accounts)
            then withError hx "Unknown account."
            else
              if not (all (\l -> any ((== tlCategory l) . catId) categories) (toList lines'))
                then withError hx "Unknown category."
                else go accounts categories aid day (spendingPayee form) lines'

createSpendingHandler :: Maybe Text -> NewSpendingForm -> AppM (Html ())
createSpendingHandler hx form = withValidSpending hx form $ \accounts categories aid day payee lines' ->
  case find ((== aid) . accId) accounts of
    Just acc | isArchived acc -> withError hx "Cannot add a transaction to an archived account."
    _
      | any (isArchivedLine categories) (toList lines') ->
          withError hx "Cannot categorize a transaction against an archived category."
      | otherwise -> do
          result <- withConn (\conn -> Db.insertSpending conn aid day payee defaultStatus lines' Nothing)
          case result of
            Left CategorizedTransactionRequiresOnBudgetAccount ->
              withError hx "Categorized transactions are not allowed on tracking accounts."
            Left _ -> withError hx "Could not create transaction."
            Right _ -> renderDefault hx

editSpendingHandler :: Maybe Text -> Int64 -> NewSpendingForm -> AppM (Html ())
editSpendingHandler hx rawId form = withValidSpending hx form $ \_accounts _categories aid day payee lines' -> do
  result <- withConn (\conn -> Db.updateSpending conn (TransactionId rawId) aid day payee lines')
  case result of
    Left CategorizedTransactionRequiresOnBudgetAccount ->
      withError hx "Categorized transactions are not allowed on tracking accounts."
    Left CannotModifyReconciledTransaction -> withError hx "Cannot edit a reconciled transaction."
    Left _ -> withError hx "Could not update transaction."
    Right _ -> renderDefault hx

-- | Whether a split line's category is archived — 'createSpendingHandler'\'s
-- own guard against new spending landing on one (the existence check
-- already happened in 'withValidSpending', so 'Nothing' here is
-- unreachable, not a silent pass).
isArchivedLine :: [Category] -> TransactionLine -> Bool
isArchivedLine categories l = maybe False isArchivedCategory (find ((== tlCategory l) . catId) categories)

-- | Parses and validates a transfer form's fields, then hands them
-- (along with the accounts just fetched to validate them) to @go@ —
-- shared by 'createTransferHandler' and 'editTransferHandler'.
withValidTransfer
  :: Maybe Text
  -> NewTransferForm
  -> ([Account] -> AccountId -> AccountId -> Day -> Cents -> AppM (Html ()))
  -> AppM (Html ())
withValidTransfer hx form go = case parseAccountId (transferFromAccountId form) of
  Nothing -> withError hx "Unknown account."
  Just fromAid -> case parseAccountId (transferToAccountId form) of
    Nothing -> withError hx "Unknown account."
    Just toAid -> case parseIsoDate (transferDate form) of
      Nothing -> withError hx "Invalid date."
      Just day -> case parsePositiveEuros (transferAmount form) of
        Nothing -> withError hx "Invalid amount."
        Just amt -> do
          accounts <- withConn Db.listAccounts
          if not (all (`elem` map accId accounts) [fromAid, toAid])
            then withError hx "Unknown account."
            else go accounts fromAid toAid day amt

createTransferHandler :: Maybe Text -> NewTransferForm -> AppM (Html ())
createTransferHandler hx form = withValidTransfer hx form $ \accounts fromAid toAid day amt ->
  if any (\acc -> accId acc `elem` [fromAid, toAid] && isArchived acc) accounts
    then withError hx "Cannot add a transaction to an archived account."
    else do
      result <- withConn (\conn -> Db.insertTransfer conn (fromAid, toAid) day defaultStatus amt)
      case result of
        Left TransferRequiresDistinctAccounts -> withError hx "A transfer needs two different accounts."
        Left TransferRequiresMatchingBudgetStatus ->
          withError hx "Cannot transfer between an on-budget and a tracking account."
        Left _ -> withError hx "Could not create transfer."
        Right _ -> renderDefault hx

editTransferHandler :: Maybe Text -> Int64 -> NewTransferForm -> AppM (Html ())
editTransferHandler hx rawId form = withValidTransfer hx form $ \_accounts fromAid toAid day amt -> do
  result <- withConn (\conn -> Db.updateTransfer conn (TransactionId rawId) (fromAid, toAid) day amt)
  case result of
    Left TransferRequiresDistinctAccounts -> withError hx "A transfer needs two different accounts."
    Left TransferRequiresMatchingBudgetStatus ->
      withError hx "Cannot transfer between an on-budget and a tracking account."
    Left CannotModifyReconciledTransaction -> withError hx "Cannot edit a reconciled transaction."
    Left _ -> withError hx "Could not update transfer."
    Right _ -> renderDefault hx

-- | Toggles one transaction between Uncleared and Cleared from the
-- register — the first step of reconciling (the second, account-wide
-- step lives on the Accounts page, see Api.Accounts). A no-op on an
-- unknown id or an already-Reconciled transaction
-- (Domain.Types.toggleCleared).
toggleClearedHandler :: Maybe Text -> Int64 -> AppM (Html ())
toggleClearedHandler hx rawId = do
  withConn (\conn -> Db.setTransactionCleared conn (TransactionId rawId))
  renderDefault hx

-- | Deletes a transaction (both legs, for a transfer) via
-- 'Db.deleteTransaction'. Blocked server-side on an already-'Reconciled'
-- transaction; the page itself never renders a Delete button for one
-- (see 'deleteButton'), so this is defense in depth, not the only
-- guard.
deleteTransactionHandler :: Maybe Text -> Int64 -> AppM (Html ())
deleteTransactionHandler hx rawId = do
  result <- withConn (\conn -> Db.deleteTransaction conn (TransactionId rawId))
  case result of
    Left CannotModifyReconciledTransaction -> withError hx "Cannot delete a reconciled transaction."
    Left _ -> withError hx "Could not delete transaction."
    Right () -> renderDefault hx

defaultStatus :: TransactionStatus
defaultStatus = Uncleared

-- | Every mutating handler's error path. Always re-renders the default
-- view (today's month, no account filter) — see the module header for
-- why a mutation doesn't thread the viewed month/filter back through.
withError :: Maybe Text -> Text -> AppM (Html ())
withError hx msg = do
  today <- localToday
  renderFragment hx (dayToYearMonth today) Nothing (Just msg)

-- | Every mutating handler's success path — see 'withError'.
renderDefault :: Maybe Text -> AppM (Html ())
renderDefault hx = do
  today <- localToday
  renderFragment hx (dayToYearMonth today) Nothing Nothing

-- | The one place that actually renders the register, for both a
-- freshly-viewed @?month=@/@?account=@ (via 'listTransactionsHandler')
-- and a mutation's default-view re-render ('withError'/'renderDefault').
-- A plain (non-HTMX) request gets a full page back — the progressive-
-- enhancement fallback for when HTMX didn't load — an HTMX request
-- gets just the @#transactions-content@ fragment it's about to swap in
-- (hx-swap="outerHTML"); see 'Api.Html.pageOrFragment'.
renderFragment :: Maybe Text -> YearMonth -> Maybe AccountId -> Maybe Text -> AppM (Html ())
renderFragment hx ym accountFilter err = do
  today <- localToday
  transactionsInMonth <- withConn (\conn -> Db.listTransactionsInMonth conn ym)
  let transactions = maybe transactionsInMonth (\aid -> filter ((== aid) . txAccount) transactionsInMonth) accountFilter
  accounts <- withConn Db.listAccounts
  categories <- withConn Db.listCategories
  pure
    ( pageOrFragment
        hx
        "Transactions"
        (transactionsContent err today ym accountFilter accounts categories transactions)
    )

transactionsContent
  :: Maybe Text -> Day -> YearMonth -> Maybe AccountId -> [Account] -> [Category] -> [Transaction] -> Html ()
transactionsContent err today ym accountFilter accounts categories transactions = div_ [id_ "transactions-content"] $ do
  errorBanner err
  monthNav ym accountFilter
  accountFilterBanner accounts accountFilter
  newInflowForm today accounts
  newSpendingForm today accounts categories
  newTransferForm today accounts
  transactionsTable accounts categories transactions

-- | @\<- Prev | YYYY-MM | Next -\>@, each a plain link to
-- @\/transactions?month=YYYY-MM@ (carrying the account filter along, if
-- one is active) — no JS needed, a full page load either way. A plain
-- @\<ul\>@, not a @\<nav\>@: see Api.Budget's identical reasoning.
monthNav :: YearMonth -> Maybe AccountId -> Html ()
monthNav ym accountFilter =
  ul_ [class_ "month-nav"] $ do
    li_ (a_ [href_ (monthLink (prevYearMonth ym))] "<- Prev")
    li_ (toHtml (yearMonthToText ym))
    li_ (a_ [href_ (monthLink (nextYearMonth ym))] "Next ->")
  where
    monthLink m = "/transactions?month=" <> yearMonthToText m <> accountQuerySuffix accountFilter
    accountQuerySuffix Nothing = ""
    accountQuerySuffix (Just (AccountId i)) = "&account=" <> Text.pack (show i)

accountFilterBanner :: [Account] -> Maybe AccountId -> Html ()
accountFilterBanner _ Nothing = mempty
accountFilterBanner accounts (Just aid) =
  p_ $ do
    toHtml ("Showing: " <> accountNameFor accounts aid <> " ")
    a_ [href_ "/transactions"] "[show all accounts]"

-- | Accounts offered in a picker: active accounts (also on-budget-only,
-- for the spending form's @onBudgetOnly@), plus — if @selected@ names
-- one the active-only filter would otherwise have dropped (an edit
-- form, showing a since-archived account) — that one account too, so
-- the @\<select\>@ never loses its currently-selected option and
-- silently reassigns the transaction to whatever's first in the list on
-- save. See the module header.
accountChoices :: Bool -> Maybe AccountId -> [Account] -> [Account]
accountChoices onBudgetOnly selected accounts = eligible ++ extra
  where
    eligible = filter (\a -> not (isArchived a) && (not onBudgetOnly || isOnBudget a)) accounts
    extra = case selected >>= \aid -> find ((== aid) . accId) accounts of
      Just acc | accId acc `notElem` map accId eligible -> [acc]
      _ -> []

-- | Categories offered in a picker: active categories, plus — same
-- reasoning as 'accountChoices' — whichever one is currently selected,
-- even if it's since been archived.
categoryChoices :: Maybe CategoryId -> [Category] -> [Category]
categoryChoices selected categories = eligible ++ extra
  where
    eligible = filter (not . isArchivedCategory) categories
    extra = case selected >>= \cid -> find ((== cid) . catId) categories of
      Just cat | catId cat `notElem` map catId eligible -> [cat]
      _ -> []

-- | @selected@ pre-selects an option — used by the edit forms to show
-- the transaction's current account; 'Nothing' (the create forms) just
-- leaves the browser's own default (the first option) in place. An
-- archived account stays labelled as such, since 'accountChoices' can
-- surface one here that no longer appears anywhere else on the page.
accountOption :: Maybe AccountId -> Account -> Html ()
accountOption selected acc =
  option_ (value_ (idText (accId acc)) : [selected_ "" | selected == Just (accId acc)]) (toHtml label)
  where
    idText (AccountId i) = Text.pack (show i)
    label = accName acc <> (if isArchived acc then " (archived)" else "")

categoryOption :: Maybe CategoryId -> Category -> Html ()
categoryOption selected cat =
  option_ (value_ (idText (catId cat)) : [selected_ "" | selected == Just (catId cat)]) (toHtml label)
  where
    idText (CategoryId i) = Text.pack (show i)
    label = catName cat <> (if isArchivedCategory cat then " (archived)" else "")

-- | Wrapped in @\<details\>@ (id @new-inflow-details@, targeted by the
-- @i@ keyboard shortcut in @static/app.js@) rather than a
-- @\<dialog\>@: plain, native, no JS needed for open/close, no focus-
-- trap to get wrong — "lightweight ... drawers" was explicitly offered
-- as the plan's simpler alternative (Track A Step 4).
newInflowForm :: Day -> [Account] -> Html ()
newInflowForm today accounts =
  details_ [id_ "new-inflow-details"] $ do
    summary_ "New Inflow"
    form_
      [ method_ "post"
      , action_ "/transactions/inflow"
      , hxPost_ "/transactions/inflow"
      , hxTarget_ "#transactions-content"
      , hxSwap_ "outerHTML"
      ]
      $ do
        select_ [name_ "inflowAccountId"] (mapM_ (accountOption Nothing) (accountChoices False Nothing accounts))
        input_ [type_ "date", name_ "inflowDate", value_ (dayText today)]
        input_ [type_ "text", name_ "inflowPayee", placeholder_ "Payee"]
        input_ [type_ "text", name_ "inflowAmount", placeholder_ "0.00 (negative = opening balance correction)"]
        button_ [type_ "submit"] "Add inflow"

-- | The same shape as 'newInflowForm', pre-filled and pointed at the
-- @edit-inflow@ route instead of @inflow@ — the "Edit" control inside
-- 'editControls'.
editInflowForm :: [Account] -> Transaction -> Cents -> Html ()
editInflowForm accounts tx amt =
  form_
    [method_ "post", action_ routePath, hxPost_ routePath, hxTarget_ "#transactions-content", hxSwap_ "outerHTML"]
    $ do
      select_ [name_ "inflowAccountId"] (mapM_ (accountOption (Just (txAccount tx))) (accountChoices False (Just (txAccount tx)) accounts))
      input_ [type_ "date", name_ "inflowDate", value_ (dayText (txDate tx))]
      input_ [type_ "text", name_ "inflowPayee", value_ (txPayee tx)]
      input_ [type_ "text", name_ "inflowAmount", value_ (centsToEuroText amt)]
      button_ [type_ "submit"] "Save"
  where
    routePath = "/transactions/" <> transactionIdText (txId tx) <> "/edit-inflow"

-- | The split editor: starts with one line, grows/shrinks via plain
-- DOM cloning in the Alpine @splitEditor@ component
-- (@static/app.js@) — no @x-for@/@\<template\>@, just
-- @lines.lastElementChild.cloneNode(true)@, which sidesteps relying on
-- more elaborate templating support from the vendored Alpine CSP
-- build. Every line's two inputs share the same @name@ attributes
-- (@lineCategoryId@\/@lineAmount@) regardless of how many lines exist
-- — 'lookupAll' on the server collects all of them, so no per-row
-- indexed naming is needed. The "Receipt total" field is never
-- submitted (no @name@ attribute): it only feeds the live client-side
-- "Unallocated" calculation, which Haskell never trusts — it still
-- derives @transactionAmount@ strictly from whatever lines actually
-- arrive (invariant 3).
-- | Wrapped in @\<details\>@ (id @new-expense-details@, the @n@
-- keyboard shortcut) — see 'newInflowForm'.
newSpendingForm :: Day -> [Account] -> [Category] -> Html ()
newSpendingForm today accounts categories =
  details_ [id_ "new-expense-details"] $ do
    summary_ "New Expense"
    form_
      [ method_ "post"
      , action_ "/transactions/spending"
      , hxPost_ "/transactions/spending"
      , hxTarget_ "#transactions-content"
      , hxSwap_ "outerHTML"
      , xData_ "splitEditor()"
      ]
      $ do
        select_ [name_ "spendingAccountId"] (mapM_ (accountOption Nothing) (accountChoices True Nothing accounts))
        input_ [type_ "date", name_ "spendingDate", value_ (dayText today)]
        input_ [type_ "text", name_ "spendingPayee", placeholder_ "Payee"]
        input_
          [ type_ "text"
          , xModel_ "receiptTotal"
          , xOn_ "input" "recalc()"
          , placeholder_ "Receipt total (optional)"
          ]
        div_ [xRef_ "lines"] (splitLineRow categories Nothing)
        button_ [type_ "button", xOn_ "click" "addLine()"] "+ Add split line"
        p_ [xText_ "remainingLabel"] ""
        button_ [type_ "submit"] "Add expense"

-- | The same shape as 'newSpendingForm', pre-filled (one row per
-- existing split line) and pointed at @edit-spending@ instead of
-- @spending@.
editSpendingForm :: [Account] -> [Category] -> Transaction -> NonEmpty TransactionLine -> Html ()
editSpendingForm accounts categories tx lines' =
  form_
    [ method_ "post"
    , action_ routePath
    , hxPost_ routePath
    , hxTarget_ "#transactions-content"
    , hxSwap_ "outerHTML"
    , xData_ "splitEditor()"
    ]
    $ do
      select_ [name_ "spendingAccountId"] (mapM_ (accountOption (Just (txAccount tx))) (accountChoices True (Just (txAccount tx)) accounts))
      input_ [type_ "date", name_ "spendingDate", value_ (dayText (txDate tx))]
      input_ [type_ "text", name_ "spendingPayee", value_ (txPayee tx)]
      input_
        [ type_ "text"
        , xModel_ "receiptTotal"
        , xOn_ "input" "recalc()"
        , placeholder_ "Receipt total (optional)"
        ]
      div_ [xRef_ "lines"] $
        mapM_ (\l -> splitLineRow categories (Just (tlCategory l, negateCents (tlAmount l)))) (toList lines')
      button_ [type_ "button", xOn_ "click" "addLine()"] "+ Add split line"
      p_ [xText_ "remainingLabel"] ""
      button_ [type_ "submit"] "Save"
  where
    routePath = "/transactions/" <> transactionIdText (txId tx) <> "/edit-spending"

-- | @prefill@ is @(category, typed amount)@ — note this is the amount
-- as the user *typed* it (positive = expense), the negation of the
-- stored, already-negated 'tlAmount' — so an edit form shows the same
-- figure a fresh entry would have asked for, not the sign-flipped
-- stored one.
splitLineRow :: [Category] -> Maybe (CategoryId, Cents) -> Html ()
splitLineRow categories prefill =
  div_ [class_ "split-line"] $ do
    select_ [name_ "lineCategoryId"] (mapM_ (categoryOption (fst <$> prefill)) (categoryChoices (fst <$> prefill) categories))
    input_
      ( [type_ "text", name_ "lineAmount", placeholder_ "0.00 (negative = refund)", xOn_ "input" "recalc()"]
          ++ maybe [] (\(_, amt) -> [value_ (centsToEuroText amt)]) prefill
      )
    button_ [type_ "button", xOn_ "click" "removeLine($event)"] "Remove"

-- | Wrapped in @\<details\>@ (id @new-transfer-details@, the @t@
-- keyboard shortcut) — see 'newInflowForm'.
newTransferForm :: Day -> [Account] -> Html ()
newTransferForm today accounts =
  details_ [id_ "new-transfer-details"] $ do
    summary_ "New Transfer"
    form_
      [ method_ "post"
      , action_ "/transactions/transfer"
      , hxPost_ "/transactions/transfer"
      , hxTarget_ "#transactions-content"
      , hxSwap_ "outerHTML"
      ]
      $ do
        select_ [name_ "transferFromAccountId"] (mapM_ (accountOption Nothing) (accountChoices False Nothing accounts))
        select_ [name_ "transferToAccountId"] (mapM_ (accountOption Nothing) (accountChoices False Nothing accounts))
        input_ [type_ "date", name_ "transferDate", value_ (dayText today)]
        input_ [type_ "number", step_ "0.01", min_ "0", name_ "transferAmount", placeholder_ "0.00"]
        button_ [type_ "submit"] "Add transfer"

-- | The same shape as 'newTransferForm', pre-filled and pointed at
-- @edit-transfer@ instead of @transfer@. @counterpartAcc@/@legAmount@
-- come from whichever leg's "Edit" was clicked (see 'editControls');
-- the stored sign tells us which side is "from" (negative — this leg
-- loses money) and which is "to" (positive), since both legs of the
-- *same* transfer get replaced together either way (there's no single
-- "the" leg being edited independently of the other).
editTransferForm :: [Account] -> Transaction -> AccountId -> Cents -> Html ()
editTransferForm accounts tx counterpartAcc legAmount =
  form_
    [method_ "post", action_ routePath, hxPost_ routePath, hxTarget_ "#transactions-content", hxSwap_ "outerHTML"]
    $ do
      select_ [name_ "transferFromAccountId"] (mapM_ (accountOption (Just fromAccId)) (accountChoices False (Just fromAccId) accounts))
      select_ [name_ "transferToAccountId"] (mapM_ (accountOption (Just toAccId)) (accountChoices False (Just toAccId) accounts))
      input_ [type_ "date", name_ "transferDate", value_ (dayText (txDate tx))]
      input_ [type_ "number", step_ "0.01", min_ "0", name_ "transferAmount", value_ (centsToEuroText absAmount)]
      button_ [type_ "submit"] "Save"
  where
    routePath = "/transactions/" <> transactionIdText (txId tx) <> "/edit-transfer"
    (fromAccId, toAccId, absAmount)
      | legAmount < zeroCents = (txAccount tx, counterpartAcc, negateCents legAmount)
      | otherwise = (counterpartAcc, txAccount tx, legAmount)

transactionsTable :: [Account] -> [Category] -> [Transaction] -> Html ()
transactionsTable accounts categories transactions = table_ $ do
  thead_
    (tr_ (mapM_ (th_ . toHtml) (["Date", "Account", "Payee", "Category", "Amount", "Status", "", "", ""] :: [Text])))
  tbody_ (mapM_ (transactionRow accounts categories) transactions)

transactionRow :: [Account] -> [Category] -> Transaction -> Html ()
transactionRow accounts categories tx = tr_ $ do
  td_ (toHtml (dayText (txDate tx)))
  td_ (toHtml (accountNameFor accounts (txAccount tx)))
  td_ (toHtml (txPayee tx))
  td_ (toHtml (categorizationText accounts categories (txCategorization tx)))
  td_ [class_ "amount"] (toHtml (centsToEuroText (transactionAmount tx)))
  td_ (toHtml (transactionStatusToText (txStatus tx)))
  td_ (clearButton tx)
  td_ (editControls accounts categories tx)
  td_ (deleteButton tx)

-- | Lets the register mark a transaction as seen on the bank statement
-- (Uncleared <-> Cleared, see Domain.Types.toggleCleared) — the first
-- step toward reconciling. No button once a transaction is
-- Reconciled: that status only changes via Api.Accounts' account-wide
-- reconcile action, never a single click here.
clearButton :: Transaction -> Html ()
clearButton tx
  | txStatus tx == Reconciled = mempty
  | otherwise =
      let routePath = "/transactions/" <> transactionIdText (txId tx) <> "/clear"
      in form_ [method_ "post", action_ routePath] $
           button_
             [type_ "submit", hxPost_ routePath, hxTarget_ "#transactions-content", hxSwap_ "outerHTML"]
             (if txStatus tx == Uncleared then "Clear" else "Unclear")

-- | A per-row @\<details\>@ holding whichever edit form matches this
-- transaction's kind ('editInflowForm'\/'editSpendingForm'\/
-- 'editTransferForm') — the plan's "inline row" alternative to a
-- @\<dialog\>@ (Track A Step 5), same reasoning as the entry drawers in
-- Step 4. Nothing renders here once a transaction is 'Reconciled':
-- there's nothing a submit could do but fail server-side anyway (see
-- 'Db.updateInflow' and friends).
editControls :: [Account] -> [Category] -> Transaction -> Html ()
editControls accounts categories tx
  | txStatus tx == Reconciled = mempty
  | otherwise =
      details_ [id_ ("edit-details-" <> transactionIdText (txId tx))] $ do
        summary_ "Edit"
        case txCategorization tx of
          Inflow amt -> editInflowForm accounts tx amt
          TransferLeg _ counterpartAcc amt -> editTransferForm accounts tx counterpartAcc amt
          Categorized ls -> editSpendingForm accounts categories tx ls

-- | No button once a transaction is 'Reconciled' — the server-side
-- guard in 'Db.deleteTransaction' is the real enforcement
-- ('CannotModifyReconciledTransaction'), this is just not offering a
-- control that can only ever fail.
deleteButton :: Transaction -> Html ()
deleteButton tx
  | txStatus tx == Reconciled = mempty
  | otherwise =
      let routePath = "/transactions/" <> transactionIdText (txId tx) <> "/delete"
      in form_ [method_ "post", action_ routePath] $
           button_
             [ type_ "submit"
             , hxPost_ routePath
             , hxTarget_ "#transactions-content"
             , hxSwap_ "outerHTML"
             , hxConfirm_ "Delete this transaction? This cannot be undone."
             ]
             "Delete"

transactionIdText :: TransactionId -> Text
transactionIdText (TransactionId i) = Text.pack (show i)

-- | An HTML @\<input type="date"\>@ value (@"YYYY-MM-DD"@) — 'Day's
-- 'Show' instance already renders that, so there's no separate format
-- string to keep in sync with 'parseIsoDate'.
dayText :: Day -> Text
dayText = Text.pack . show

categorizationText :: [Account] -> [Category] -> Categorization -> Text
categorizationText _ categories (Categorized ls) =
  Text.intercalate ", " (map (categoryNameFor categories) (map lineCategory (toList ls)))
  where
    lineCategory (TransactionLine cid _) = cid
categorizationText _ _ (Inflow _) = "Ready to Assign"
categorizationText accounts _ (TransferLeg _ counterpartAcc _) = "Transfer: " <> accountNameFor accounts counterpartAcc

accountNameFor :: [Account] -> AccountId -> Text
accountNameFor accounts aid = case filter ((== aid) . accId) accounts of
  (a : _) -> accName a
  []      -> "—"

categoryNameFor :: [Category] -> CategoryId -> Text
categoryNameFor categories cid = case filter ((== cid) . catId) categories of
  (c : _) -> catName c
  []      -> "—"

-- | Parses a decimal id out of an HTML @\<select\>@'s value, total and
-- without 'Prelude.read' (CLAUDE.md "Total functions only").
parseAccountId :: Text -> Maybe AccountId
parseAccountId t = AccountId <$> parseInt64 t

parseCategoryId :: Text -> Maybe CategoryId
parseCategoryId t = CategoryId <$> parseInt64 t

-- | Parses every (category, amount) pair the split editor submitted,
-- in order, short-circuiting on the first invalid one. The amount is
-- *signed* (via 'Api.Money.parseNonZeroSignedEuros', not
-- 'Api.Money.parsePositiveEuros'): a negative line is a refund/credit
-- against that category — see the module header.
parseSplitLines :: [(Text, Text)] -> Either Text [TransactionLine]
parseSplitLines = traverse parseOneLine
  where
    parseOneLine (catText, amtText) = case parseCategoryId catText of
      Nothing -> Left "Unknown category."
      Just cid -> case parseNonZeroSignedEuros amtText of
        Nothing -> Left "Invalid amount."
        Just amt -> Right (TransactionLine cid (negateCents amt))

parseInt64 :: Text -> Maybe Int64
parseInt64 t = case TextRead.decimal t of
  Right (n, rest) | Text.null rest -> Just n
  _                                -> Nothing

-- | Parses an HTML @\<input type="date"\>@ value (@"YYYY-MM-DD"@),
-- total and without 'Data.Time.Format.parseTimeM' (which can throw).
parseIsoDate :: Text -> Maybe Day
parseIsoDate t = case Text.splitOn "-" t of
  [y, m, d] -> do
    y' <- parseInt64 y
    m' <- parseInt64 m
    d' <- parseInt64 d
    fromGregorianValid (fromIntegral y') (fromIntegral m') (fromIntegral d')
  _ -> Nothing
