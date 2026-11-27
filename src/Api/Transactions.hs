-- | Routes and handlers for transactions: keep thin, HTTP translation
-- only (CLAUDE.md "Architecture") — the real logic already lives in
-- 'Db.Transaction'/'Domain.Transaction'.
--
-- The spending form supports splits across up to three categories
-- (amounts typed as positive expenses, stored negated) without any
-- client-side JS: the first line is required, the other two are
-- simply skipped if their amount is left blank (see 'parseOptionalLine').
-- A genuine arbitrary-length split (already supported end-to-end by
-- 'Db.Transaction.insertSpending'/'Domain.Transaction') would need a
-- dynamic "add another line" control; three fixed slots cover the
-- common case without that complexity.
--
-- The register always shows the *current* calendar month — there's no
-- month picker yet, consistent with there being no multi-month
-- rollover orchestrator either (see DECISIONS.md §8, H-5).
module Api.Transactions
  ( TransactionsApi
  , transactionsServer
  ) where

import Control.Monad.IO.Class (liftIO)
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty ((:|)), toList)
import Data.Maybe (catMaybes)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Read as TextRead
import Data.Time (Day, fromGregorianValid, getCurrentTime, utctDay)
import GHC.Generics (Generic)
import Lucid
import Servant
import Servant.HTML.Lucid (HTML)

import Api.Html (errorBanner, hxPost_, hxSwap_, hxTarget_, pageOrFragment)
import Api.Monad (AppM, withConn)
import Api.Money (centsToEuroText, parsePositiveEuros)
import qualified Db.Account as Db
import qualified Db.Category as Db
import qualified Db.Transaction as Db
import Domain.Account (Account (accId, accName), isArchived)
import Domain.Category (Category (catId, catName), isArchivedCategory)
import Domain.Error (DomainError (..))
import Domain.Transaction
  ( Categorization (Categorized, Inflow, TransferLeg)
  , Transaction (txCategorization, txDate, txId, txPayee, txStatus)
  , TransactionLine (TransactionLine, tlCategory)
  , transactionAmount
  )
import Domain.Types
  ( AccountId (AccountId)
  , CategoryId (CategoryId)
  , TransactionId (TransactionId)
  , TransactionStatus (Reconciled, Uncleared)
  , dayToYearMonth
  , negateCents
  , transactionStatusToText
  )
import Web.FormUrlEncoded (FromForm)

type TransactionsApi =
  "transactions" :> Get '[HTML] (Html ())
    :<|> Header "HX-Request" Text :> "transactions" :> "inflow" :> ReqBody '[FormUrlEncoded] NewInflowForm :> Post '[HTML] (Html ())
    :<|> Header "HX-Request" Text :> "transactions" :> "spending" :> ReqBody '[FormUrlEncoded] NewSpendingForm :> Post '[HTML] (Html ())
    :<|> Header "HX-Request" Text :> "transactions" :> "transfer" :> ReqBody '[FormUrlEncoded] NewTransferForm :> Post '[HTML] (Html ())
    :<|> Header "HX-Request" Text :> "transactions" :> Capture "id" Int64 :> "clear" :> Post '[HTML] (Html ())

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

data NewSpendingForm = NewSpendingForm
  { spendingAccountId   :: Text
  , spendingDate        :: Text
  , spendingPayee       :: Text
  , spendingCategoryId1 :: Text
  , spendingAmount1     :: Text
  , spendingCategoryId2 :: Text
  , spendingAmount2     :: Text
  , spendingCategoryId3 :: Text
  , spendingAmount3     :: Text
  }
  deriving stock (Generic)
  deriving anyclass (FromForm)

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

listTransactionsHandler :: AppM (Html ())
listTransactionsHandler = renderFragment Nothing Nothing

createInflowHandler :: Maybe Text -> NewInflowForm -> AppM (Html ())
createInflowHandler hx form = case parseAccountId (inflowAccountId form) of
  Nothing -> withError hx "Unknown account."
  Just aid -> case parseIsoDate (inflowDate form) of
    Nothing -> withError hx "Invalid date."
    Just day -> case parsePositiveEuros (inflowAmount form) of
      Nothing -> withError hx "Invalid amount."
      Just amt -> do
        accounts <- withConn Db.listAccounts
        if not (any ((== aid) . accId) accounts)
          then withError hx "Unknown account."
          else do
            _ <- withConn (\conn -> Db.insertInflow conn aid day (inflowPayee form) defaultStatus amt Nothing)
            renderFragment hx Nothing

createSpendingHandler :: Maybe Text -> NewSpendingForm -> AppM (Html ())
createSpendingHandler hx form = case parseAccountId (spendingAccountId form) of
  Nothing -> withError hx "Unknown account."
  Just aid -> case parseIsoDate (spendingDate form) of
    Nothing -> withError hx "Invalid date."
    Just day -> case parseRequiredLine (spendingCategoryId1 form) (spendingAmount1 form) of
      Left err -> withError hx err
      Right line1 -> case parseOptionalLine (spendingCategoryId2 form) (spendingAmount2 form) of
        Left err -> withError hx err
        Right maybeLine2 -> case parseOptionalLine (spendingCategoryId3 form) (spendingAmount3 form) of
          Left err -> withError hx err
          Right maybeLine3 -> do
            let lines' = line1 :| catMaybes [maybeLine2, maybeLine3]
            accounts <- withConn Db.listAccounts
            categories <- withConn Db.listCategories
            if not (any ((== aid) . accId) accounts)
              then withError hx "Unknown account."
              else
                if not (all (\l -> any ((== tlCategory l) . catId) categories) (toList lines'))
                  then withError hx "Unknown category."
                  else do
                    result <-
                      withConn
                        (\conn -> Db.insertSpending conn aid day (spendingPayee form) defaultStatus lines' Nothing)
                    case result of
                      Left CategorizedTransactionRequiresOnBudgetAccount ->
                        withError hx "Categorized transactions are not allowed on tracking accounts."
                      Left _ -> withError hx "Could not create transaction."
                      Right _ -> renderFragment hx Nothing

createTransferHandler :: Maybe Text -> NewTransferForm -> AppM (Html ())
createTransferHandler hx form = case parseAccountId (transferFromAccountId form) of
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
            else do
              result <- withConn (\conn -> Db.insertTransfer conn (fromAid, toAid) day defaultStatus amt)
              case result of
                Left TransferRequiresDistinctAccounts -> withError hx "A transfer needs two different accounts."
                Left TransferRequiresMatchingBudgetStatus ->
                  withError hx "Cannot transfer between an on-budget and a tracking account."
                Left _ -> withError hx "Could not create transfer."
                Right _ -> renderFragment hx Nothing

-- | Toggles one transaction between Uncleared and Cleared from the
-- register — the first step of reconciling (the second, account-wide
-- step lives on the Accounts page, see Api.Accounts). A no-op on an
-- unknown id or an already-Reconciled transaction
-- (Domain.Types.toggleCleared).
toggleClearedHandler :: Maybe Text -> Int64 -> AppM (Html ())
toggleClearedHandler hx rawId = do
  withConn (\conn -> Db.setTransactionCleared conn (TransactionId rawId))
  renderFragment hx Nothing

defaultStatus :: TransactionStatus
defaultStatus = Uncleared

withError :: Maybe Text -> Text -> AppM (Html ())
withError hx msg = renderFragment hx (Just msg)

-- | Every mutating handler renders back through this. A plain
-- (non-HTMX) request gets a full page back — the progressive-
-- enhancement fallback for when HTMX didn't load — an HTMX request
-- gets just the @#transactions-content@ fragment it's about to swap in
-- (hx-swap="outerHTML"); see 'Api.Html.pageOrFragment'.
renderFragment :: Maybe Text -> Maybe Text -> AppM (Html ())
renderFragment hx err = do
  today <- liftIO getCurrentTime
  let ym = dayToYearMonth (utctDay today)
  transactions <- withConn (\conn -> Db.listTransactionsInMonth conn ym)
  accounts <- withConn Db.listAccounts
  categories <- withConn Db.listCategories
  pure (pageOrFragment hx "Transactions" (transactionsContent err accounts categories transactions))

transactionsContent :: Maybe Text -> [Account] -> [Category] -> [Transaction] -> Html ()
transactionsContent err accounts categories transactions = div_ [id_ "transactions-content"] $ do
  errorBanner err
  newInflowForm accounts
  newSpendingForm accounts categories
  newTransferForm accounts
  transactionsTable accounts categories transactions

activeAccounts :: [Account] -> [Account]
activeAccounts = filter (not . isArchived)

activeCategories :: [Category] -> [Category]
activeCategories = filter (not . isArchivedCategory)

accountOption :: Account -> Html ()
accountOption acc = option_ [value_ (idText (accId acc))] (toHtml (accName acc))
  where
    idText (AccountId i) = Text.pack (show i)

categoryOption :: Category -> Html ()
categoryOption cat = option_ [value_ (idText (catId cat))] (toHtml (catName cat))
  where
    idText (CategoryId i) = Text.pack (show i)

newInflowForm :: [Account] -> Html ()
newInflowForm accounts =
  form_
    [ method_ "post"
    , action_ "/transactions/inflow"
    , hxPost_ "/transactions/inflow"
    , hxTarget_ "#transactions-content"
    , hxSwap_ "outerHTML"
    ]
    $ do
      select_ [name_ "inflowAccountId"] (mapM_ accountOption (activeAccounts accounts))
      input_ [type_ "date", name_ "inflowDate"]
      input_ [type_ "text", name_ "inflowPayee", placeholder_ "Payee"]
      input_ [type_ "number", step_ "0.01", min_ "0", name_ "inflowAmount", placeholder_ "0.00"]
      button_ [type_ "submit"] "Add inflow"

newSpendingForm :: [Account] -> [Category] -> Html ()
newSpendingForm accounts categories =
  form_
    [ method_ "post"
    , action_ "/transactions/spending"
    , hxPost_ "/transactions/spending"
    , hxTarget_ "#transactions-content"
    , hxSwap_ "outerHTML"
    ]
    $ do
      select_ [name_ "spendingAccountId"] (mapM_ accountOption (activeAccounts accounts))
      input_ [type_ "date", name_ "spendingDate"]
      input_ [type_ "text", name_ "spendingPayee", placeholder_ "Payee"]
      splitLine "spendingCategoryId1" "spendingAmount1" "0.00" categories
      splitLine "spendingCategoryId2" "spendingAmount2" "0.00 (optional)" categories
      splitLine "spendingCategoryId3" "spendingAmount3" "0.00 (optional)" categories
      button_ [type_ "submit"] "Add expense"

-- | One split line: a category picker plus an amount. Leaving the
-- amount blank on an optional line (see 'parseOptionalLine') is how a
-- split with fewer than three lines works, without JS to add/remove
-- rows.
splitLine :: Text -> Text -> Text -> [Category] -> Html ()
splitLine categoryFieldName amountFieldName amountPlaceholder categories = do
  select_ [name_ categoryFieldName] (mapM_ categoryOption (activeCategories categories))
  input_ [type_ "number", step_ "0.01", min_ "0", name_ amountFieldName, placeholder_ amountPlaceholder]

newTransferForm :: [Account] -> Html ()
newTransferForm accounts =
  form_
    [ method_ "post"
    , action_ "/transactions/transfer"
    , hxPost_ "/transactions/transfer"
    , hxTarget_ "#transactions-content"
    , hxSwap_ "outerHTML"
    ]
    $ do
      select_ [name_ "transferFromAccountId"] (mapM_ accountOption (activeAccounts accounts))
      select_ [name_ "transferToAccountId"] (mapM_ accountOption (activeAccounts accounts))
      input_ [type_ "date", name_ "transferDate"]
      input_ [type_ "number", step_ "0.01", min_ "0", name_ "transferAmount", placeholder_ "0.00"]
      button_ [type_ "submit"] "Add transfer"

transactionsTable :: [Account] -> [Category] -> [Transaction] -> Html ()
transactionsTable accounts categories transactions = table_ $ do
  thead_ (tr_ (mapM_ (th_ . toHtml) (["Date", "Payee", "Category", "Amount", "Status", ""] :: [Text])))
  tbody_ (mapM_ (transactionRow accounts categories) transactions)

transactionRow :: [Account] -> [Category] -> Transaction -> Html ()
transactionRow accounts categories tx = tr_ $ do
  td_ (toHtml (Text.pack (show (txDate tx))))
  td_ (toHtml (txPayee tx))
  td_ (toHtml (categorizationText accounts categories (txCategorization tx)))
  td_ [class_ "amount"] (toHtml (centsToEuroText (transactionAmount tx)))
  td_ (toHtml (transactionStatusToText (txStatus tx)))
  td_ (clearButton tx)

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

transactionIdText :: TransactionId -> Text
transactionIdText (TransactionId i) = Text.pack (show i)

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

-- | One split line that's always part of the transaction (the form's
-- first line) — a category and an amount, both required.
parseRequiredLine :: Text -> Text -> Either Text TransactionLine
parseRequiredLine catText amtText = case parseCategoryId catText of
  Nothing -> Left "Unknown category."
  Just cid -> case parsePositiveEuros amtText of
    Nothing -> Left "Invalid amount."
    Just amt -> Right (TransactionLine cid (negateCents amt))

-- | A split line the user might not be using (the form's second/third
-- line): a blank amount means "skip this line" — how the spending form
-- supports an optional extra split without any client-side JS to
-- add/remove rows. A non-blank amount is validated exactly like
-- 'parseRequiredLine'.
parseOptionalLine :: Text -> Text -> Either Text (Maybe TransactionLine)
parseOptionalLine catText amtText
  | Text.null (Text.strip amtText) = Right Nothing
  | otherwise = Just <$> parseRequiredLine catText amtText

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
