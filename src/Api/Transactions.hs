-- | Routes and handlers for transactions: keep thin, HTTP translation
-- only (CLAUDE.md "Architecture") — the real logic already lives in
-- 'Db.Transaction'/'Domain.Transaction'.
--
-- v0.1 UI simplification (full split entry is already supported by
-- 'Db.Transaction.insertSpending'/'Domain.Transaction', just not
-- exposed here yet): a categorized transaction is entered as a single
-- line, as an expense (the amount typed is positive, stored negated).
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
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Read as TextRead
import Data.Time (Day, fromGregorianValid, getCurrentTime, utctDay)
import GHC.Generics (Generic)
import Lucid
import Servant
import Servant.HTML.Lucid (HTML)

import Api.Html (errorBanner, hxPost_, hxSwap_, hxTarget_, page)
import Api.Monad (AppM, withConn)
import qualified Db.Account as Db
import qualified Db.Category as Db
import qualified Db.Transaction as Db
import Domain.Account (Account (accId, accName), isArchived)
import Domain.Category (Category (catId, catName), isArchivedCategory)
import Domain.Error (DomainError (..))
import Domain.Transaction
  ( Categorization (Categorized, Inflow, TransferLeg)
  , Transaction (txCategorization, txDate, txId, txPayee, txStatus)
  , TransactionLine (TransactionLine)
  , transactionAmount
  )
import Domain.Types
  ( AccountId (AccountId)
  , CategoryId (CategoryId)
  , Cents
  , TransactionId (TransactionId)
  , TransactionStatus (Reconciled, Uncleared)
  , centsValue
  , cents
  , dayToYearMonth
  , negateCents
  , transactionStatusToText
  )
import Web.FormUrlEncoded (FromForm)

type TransactionsApi =
  "transactions" :> Get '[HTML] (Html ())
    :<|> "transactions" :> "inflow" :> ReqBody '[FormUrlEncoded] NewInflowForm :> Post '[HTML] (Html ())
    :<|> "transactions" :> "spending" :> ReqBody '[FormUrlEncoded] NewSpendingForm :> Post '[HTML] (Html ())
    :<|> "transactions" :> "transfer" :> ReqBody '[FormUrlEncoded] NewTransferForm :> Post '[HTML] (Html ())
    :<|> "transactions" :> Capture "id" Int64 :> "clear" :> Post '[HTML] (Html ())

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
  { spendingAccountId  :: Text
  , spendingCategoryId :: Text
  , spendingDate       :: Text
  , spendingPayee      :: Text
  , spendingAmount     :: Text
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
listTransactionsHandler = renderFragment Nothing

createInflowHandler :: NewInflowForm -> AppM (Html ())
createInflowHandler form = case parseAccountId (inflowAccountId form) of
  Nothing -> withError "Unknown account."
  Just aid -> case parseIsoDate (inflowDate form) of
    Nothing -> withError "Invalid date."
    Just day -> case parseEuros (inflowAmount form) of
      Nothing -> withError "Invalid amount."
      Just amt -> do
        accounts <- withConn Db.listAccounts
        if not (any ((== aid) . accId) accounts)
          then withError "Unknown account."
          else do
            _ <- withConn (\conn -> Db.insertInflow conn aid day (inflowPayee form) defaultStatus amt Nothing)
            renderFragment Nothing

createSpendingHandler :: NewSpendingForm -> AppM (Html ())
createSpendingHandler form = case parseAccountId (spendingAccountId form) of
  Nothing -> withError "Unknown account."
  Just aid -> case parseCategoryId (spendingCategoryId form) of
    Nothing -> withError "Unknown category."
    Just cid -> case parseIsoDate (spendingDate form) of
      Nothing -> withError "Invalid date."
      Just day -> case parseEuros (spendingAmount form) of
        Nothing -> withError "Invalid amount."
        Just amt -> do
          accounts <- withConn Db.listAccounts
          categories <- withConn Db.listCategories
          if not (any ((== aid) . accId) accounts)
            then withError "Unknown account."
            else
              if not (any ((== cid) . catId) categories)
                then withError "Unknown category."
                else do
                  let line = TransactionLine cid (negateCents amt) :| []
                  result <-
                    withConn
                      (\conn -> Db.insertSpending conn aid day (spendingPayee form) defaultStatus line Nothing)
                  case result of
                    Left CategorizedTransactionRequiresOnBudgetAccount ->
                      withError "Categorized transactions are not allowed on tracking accounts."
                    Left _ -> withError "Could not create transaction."
                    Right _ -> renderFragment Nothing

createTransferHandler :: NewTransferForm -> AppM (Html ())
createTransferHandler form = case parseAccountId (transferFromAccountId form) of
  Nothing -> withError "Unknown account."
  Just fromAid -> case parseAccountId (transferToAccountId form) of
    Nothing -> withError "Unknown account."
    Just toAid -> case parseIsoDate (transferDate form) of
      Nothing -> withError "Invalid date."
      Just day -> case parseEuros (transferAmount form) of
        Nothing -> withError "Invalid amount."
        Just amt -> do
          accounts <- withConn Db.listAccounts
          if not (all (`elem` map accId accounts) [fromAid, toAid])
            then withError "Unknown account."
            else do
              result <- withConn (\conn -> Db.insertTransfer conn (fromAid, toAid) day defaultStatus amt)
              case result of
                Left TransferRequiresDistinctAccounts -> withError "A transfer needs two different accounts."
                Left TransferRequiresMatchingBudgetStatus ->
                  withError "Cannot transfer between an on-budget and a tracking account."
                Left _ -> withError "Could not create transfer."
                Right _ -> renderFragment Nothing

-- | Toggles one transaction between Uncleared and Cleared from the
-- register — the first step of reconciling (the second, account-wide
-- step lives on the Accounts page, see Api.Accounts). A no-op on an
-- unknown id or an already-Reconciled transaction
-- (Domain.Types.toggleCleared).
toggleClearedHandler :: Int64 -> AppM (Html ())
toggleClearedHandler rawId = do
  withConn (\conn -> Db.setTransactionCleared conn (TransactionId rawId))
  renderFragment Nothing

defaultStatus :: TransactionStatus
defaultStatus = Uncleared

withError :: Text -> AppM (Html ())
withError msg = renderFragment (Just msg)

-- | Every mutating handler renders back exactly this fragment: HTMX
-- swaps @#transactions-content@ (hx-swap="outerHTML"), so the page
-- updates without a full navigation.
renderFragment :: Maybe Text -> AppM (Html ())
renderFragment err = do
  today <- liftIO getCurrentTime
  let ym = dayToYearMonth (utctDay today)
  transactions <- withConn (\conn -> Db.listTransactionsInMonth conn ym)
  accounts <- withConn Db.listAccounts
  categories <- withConn Db.listCategories
  pure (page "Transactions" (transactionsContent err accounts categories transactions))

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
  form_ [hxPost_ "/transactions/inflow", hxTarget_ "#transactions-content", hxSwap_ "outerHTML"] $ do
    select_ [name_ "inflowAccountId"] (mapM_ accountOption (activeAccounts accounts))
    input_ [type_ "date", name_ "inflowDate"]
    input_ [type_ "text", name_ "inflowPayee", placeholder_ "Payee"]
    input_ [type_ "number", step_ "0.01", min_ "0", name_ "inflowAmount", placeholder_ "0.00"]
    button_ [type_ "submit"] "Add inflow"

newSpendingForm :: [Account] -> [Category] -> Html ()
newSpendingForm accounts categories =
  form_ [hxPost_ "/transactions/spending", hxTarget_ "#transactions-content", hxSwap_ "outerHTML"] $ do
    select_ [name_ "spendingAccountId"] (mapM_ accountOption (activeAccounts accounts))
    select_ [name_ "spendingCategoryId"] (mapM_ categoryOption (activeCategories categories))
    input_ [type_ "date", name_ "spendingDate"]
    input_ [type_ "text", name_ "spendingPayee", placeholder_ "Payee"]
    input_ [type_ "number", step_ "0.01", min_ "0", name_ "spendingAmount", placeholder_ "0.00"]
    button_ [type_ "submit"] "Add expense"

newTransferForm :: [Account] -> Html ()
newTransferForm accounts =
  form_ [hxPost_ "/transactions/transfer", hxTarget_ "#transactions-content", hxSwap_ "outerHTML"] $ do
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
  td_ (toHtml (centsToEuroText (transactionAmount tx)))
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
      button_
        [ hxPost_ ("/transactions/" <> transactionIdText (txId tx) <> "/clear")
        , hxTarget_ "#transactions-content"
        , hxSwap_ "outerHTML"
        ]
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

-- | Parses a decimal id out of an HTML @\<select\>@'s value, total and
-- without 'Prelude.read' (CLAUDE.md "Total functions only").
parseAccountId :: Text -> Maybe AccountId
parseAccountId t = AccountId <$> parseInt64 t

parseCategoryId :: Text -> Maybe CategoryId
parseCategoryId t = CategoryId <$> parseInt64 t

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
