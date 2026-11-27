-- | Routes and handlers for the monthly budget page: keep thin, HTTP
-- translation only (CLAUDE.md "Architecture") — the real logic already
-- lives in 'Db.Assignment'/'Domain.Budget'.
--
-- Shows the *current* calendar month (no month picker yet, like
-- "Api.Transactions"), but — unlike the first version of this page —
-- its carry-in (both per-category and Ready to Assign) is now folded
-- forward from every earlier month with any activity via
-- 'Domain.Budget.rolloverMonths', instead of always starting at
-- 'zeroCents' (DECISIONS.md §8, H-5).
module Api.Budget
  ( BudgetApi
  , budgetServer
  ) where

import Control.Monad.IO.Class (liftIO)
import Data.Int (Int64)
import Data.List (find)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Read as TextRead
import Data.Time (getCurrentTime, utctDay)
import GHC.Generics (Generic)
import Lucid
import Servant
import Servant.HTML.Lucid (HTML)

import Api.Html (errorBanner, hxPost_, hxSwap_, hxTarget_, page)
import Api.Monad (AppM, withConn)
import qualified Db.Account as Db
import qualified Db.Assignment as Db
import qualified Db.Category as Db
import qualified Db.Transaction as Db
import Domain.Budget
  ( Assignment (asgMonth)
  , CategoryMonth (cmActivity, cmAssigned, cmCategory)
  , MonthlyBudget (..)
  , available
  , rolloverMonths
  )
import Domain.Category
  ( Category (catGroupId, catId, catName)
  , CategoryGroup (cgId, cgName)
  , isArchivedCategory
  )
import Domain.Transaction (Transaction, txDate)
import Domain.Types
  ( Cents
  , CategoryId (CategoryId)
  , YearMonth
  , centsValue
  , cents
  , dayToYearMonth
  , nextYearMonth
  , zeroCents
  )
import Web.FormUrlEncoded (FromForm)

type BudgetApi =
  "budget" :> Get '[HTML] (Html ())
    :<|> "budget" :> "assign" :> ReqBody '[FormUrlEncoded] NewAssignmentForm :> Post '[HTML] (Html ())

-- | Field names must match the @name@ attributes of 'newAssignmentForm'
-- below — 'FromForm' parses by field name.
data NewAssignmentForm = NewAssignmentForm
  { assignCategoryId :: Text
  , assignAmount     :: Text
  }
  deriving stock (Generic)
  deriving anyclass (FromForm)

budgetServer :: ServerT BudgetApi AppM
budgetServer = listBudgetHandler :<|> assignHandler

listBudgetHandler :: AppM (Html ())
listBudgetHandler = renderFragment Nothing

assignHandler :: NewAssignmentForm -> AppM (Html ())
assignHandler form = case parseCategoryId (assignCategoryId form) of
  Nothing -> withError "Unknown category."
  Just cid -> case parseEuros (assignAmount form) of
    Nothing -> withError "Invalid amount."
    Just amt -> do
      categories <- withConn Db.listCategories
      if not (any ((== cid) . catId) categories)
        then withError "Unknown category."
        else do
          ym <- currentYearMonth
          withConn (\conn -> Db.setAssignment conn cid ym amt)
          renderFragment Nothing

withError :: Text -> AppM (Html ())
withError msg = renderFragment (Just msg)

-- | Every mutating handler renders back exactly this fragment: HTMX
-- swaps @#budget-content@ (hx-swap="outerHTML"), so the page updates
-- without a full navigation.
renderFragment :: Maybe Text -> AppM (Html ())
renderFragment err = do
  ym <- currentYearMonth
  accounts <- withConn Db.listAccounts
  groups <- withConn Db.listCategoryGroups
  categories <- withConn Db.listCategories
  assignments <- withConn Db.listAllAssignments
  txs <- withConn Db.listAllTransactions
  let categoryIds = map catId categories
      months = monthsThrough ym assignments txs
      budgets = rolloverMonths accounts categoryIds months assignments txs
      currentBudget = currentMonthBudget ym budgets
  pure (page "Budget" (budgetContent err groups categories (mbCategoryMonths currentBudget) (mbReadyToAssign currentBudget)))

currentYearMonth :: AppM YearMonth
currentYearMonth = dayToYearMonth . utctDay <$> liftIO getCurrentTime

-- | Every month from the earliest assignment/transaction through the
-- current one, ascending — what 'rolloverMonths' needs to fold the
-- carry/Ready-to-Assign all the way forward to @currentMonth@ (rather
-- than restarting at 'zeroCents' every time, DECISIONS.md §8 H-5). With
-- no history yet, that's just @[currentMonth]@.
monthsThrough :: YearMonth -> [Assignment] -> [Transaction] -> [YearMonth]
monthsThrough currentMonth assignments txs = takeWhile (<= end) (iterate nextYearMonth start)
  where
    activityMonths = map asgMonth assignments ++ map (dayToYearMonth . txDate) txs
    start = foldl' min currentMonth activityMonths
    end = foldl' max currentMonth activityMonths

-- | The 'MonthlyBudget' for @currentMonth@ out of what 'rolloverMonths'
-- folded. The 'Nothing' branch is unreachable: 'monthsThrough' always
-- includes @currentMonth@, so 'rolloverMonths' always produces a
-- matching entry — kept total (no 'Prelude.head'/partial pattern)
-- rather than relying on that invariant with a crash.
currentMonthBudget :: YearMonth -> [MonthlyBudget] -> MonthlyBudget
currentMonthBudget currentMonth budgets =
  case find ((== currentMonth) . mbMonth) budgets of
    Just mb -> mb
    Nothing -> MonthlyBudget currentMonth [] zeroCents

budgetContent :: Maybe Text -> [CategoryGroup] -> [Category] -> [CategoryMonth] -> Cents -> Html ()
budgetContent err groups categories categoryMonths rta = div_ [id_ "budget-content"] $ do
  errorBanner err
  readyToAssignBanner rta
  newAssignmentForm categories
  budgetTable groups categories categoryMonths

readyToAssignBanner :: Cents -> Html ()
readyToAssignBanner rta = p_ (toHtml ("Ready to Assign: " <> centsToEuroText rta))

newAssignmentForm :: [Category] -> Html ()
newAssignmentForm categories =
  form_ [hxPost_ "/budget/assign", hxTarget_ "#budget-content", hxSwap_ "outerHTML"] $ do
    select_ [name_ "assignCategoryId"] (mapM_ categoryOption (activeCategories categories))
    input_ [type_ "number", step_ "0.01", min_ "0", name_ "assignAmount", placeholder_ "0.00"]
    button_ [type_ "submit"] "Assign"

activeCategories :: [Category] -> [Category]
activeCategories = filter (not . isArchivedCategory)

categoryOption :: Category -> Html ()
categoryOption cat = option_ [value_ (categoryIdText (catId cat))] (toHtml (catName cat))

budgetTable :: [CategoryGroup] -> [Category] -> [CategoryMonth] -> Html ()
budgetTable groups categories categoryMonths = table_ $ do
  thead_ (tr_ (mapM_ (th_ . toHtml) (["Category", "Group", "Assigned", "Activity", "Available"] :: [Text])))
  tbody_ (mapM_ (categoryMonthRow groups categories) categoryMonths)

categoryMonthRow :: [CategoryGroup] -> [Category] -> CategoryMonth -> Html ()
categoryMonthRow groups categories cm = tr_ $ do
  td_ (toHtml (categoryNameFor categories (cmCategory cm)))
  td_ (toHtml (groupNameFor groups categories (cmCategory cm)))
  td_ (toHtml (centsToEuroText (cmAssigned cm)))
  td_ (toHtml (centsToEuroText (cmActivity cm)))
  td_ (toHtml (centsToEuroText (available cm)))

categoryNameFor :: [Category] -> CategoryId -> Text
categoryNameFor categories cid = case filter ((== cid) . catId) categories of
  (c : _) -> catName c
  []      -> "—"

groupNameFor :: [CategoryGroup] -> [Category] -> CategoryId -> Text
groupNameFor groups categories cid = case filter ((== cid) . catId) categories of
  (c : _) -> case filter ((== catGroupId c) . cgId) groups of
    (g : _) -> cgName g
    []      -> "—"
  [] -> "—"

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

categoryIdText :: CategoryId -> Text
categoryIdText (CategoryId i) = Text.pack (show i)

-- | Parses a decimal id out of an HTML @\<select\>@'s value, total and
-- without 'Prelude.read' (CLAUDE.md "Total functions only").
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
