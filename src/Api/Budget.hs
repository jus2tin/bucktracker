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

import Api.Html
  ( errorBanner
  , hxPost_
  , hxSwap_
  , hxTarget_
  , pageOrFragment
  , xData_
  , xModel_
  , xOn_
  , xRef_
  , xShow_
  , xText_
  )
import Api.Monad (AppM, withConn)
import Api.Money (centsToEuroText, parseSignedEuros)
import qualified Db.Account as Db
import qualified Db.Assignment as Db
import qualified Db.Category as Db
import qualified Db.Transaction as Db
import Domain.Budget
  ( Assignment (asgMonth)
  , CategoryMonth (cmActivity, cmAssigned, cmCarriedIn, cmCategory)
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
import Domain.Types (Cents, CategoryId (CategoryId), YearMonth, dayToYearMonth, nextYearMonth, zeroCents)
import Web.FormUrlEncoded (FromForm)

type BudgetApi =
  "budget" :> Get '[HTML] (Html ())
    :<|> Header "HX-Request" Text :> "budget" :> "assign" :> ReqBody '[FormUrlEncoded] NewAssignmentForm :> Post '[HTML] (Html ())

-- | Field names must match the @name@ attributes of 'assignedCell'
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
listBudgetHandler = renderFragment Nothing Nothing

-- | Assigning is signed on purpose (DECISIONS.md §12, Architect review
-- S-2): once money has rolled over into a category from a previous
-- month, the only way to move it back to Ready to Assign is setting
-- this month's assigned amount *negative* (e.g. @-50.00@ against a
-- carried-in €50) — 'Domain.Budget.available' already handles that
-- arithmetic correctly, the old unsigned-only parser was the only
-- thing stopping it from ever being reachable.
assignHandler :: Maybe Text -> NewAssignmentForm -> AppM (Html ())
assignHandler hx form = case parseCategoryId (assignCategoryId form) of
  Nothing -> withError hx "Unknown category."
  Just cid -> case parseSignedEuros (assignAmount form) of
    Nothing -> withError hx "Invalid amount."
    Just amt -> do
      categories <- withConn Db.listCategories
      if not (any ((== cid) . catId) categories)
        then withError hx "Unknown category."
        else do
          ym <- currentYearMonth
          withConn (\conn -> Db.setAssignment conn cid ym amt)
          renderFragment hx Nothing

withError :: Maybe Text -> Text -> AppM (Html ())
withError hx msg = renderFragment hx (Just msg)

-- | Every mutating handler renders back through this. A plain
-- (non-HTMX) request gets a full page back — the progressive-
-- enhancement fallback for when HTMX didn't load — an HTMX request
-- gets just the @#budget-content@ fragment it's about to swap in
-- (hx-swap="outerHTML"); see 'Api.Html.pageOrFragment'.
renderFragment :: Maybe Text -> Maybe Text -> AppM (Html ())
renderFragment hx err = do
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
  pure
    ( pageOrFragment
        hx
        "Budget"
        (budgetContent err groups categories (mbCategoryMonths currentBudget) (mbReadyToAssign currentBudget))
    )

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
  budgetTable groups categories categoryMonths

readyToAssignBanner :: Cents -> Html ()
readyToAssignBanner rta = p_ (toHtml ("Ready to Assign: " <> centsToEuroText rta))

-- | Categories are grouped visually under their 'CategoryGroup'
-- heading instead of repeating the group name as a flat table column.
-- An archived category whose 'cmCarriedIn'/'cmAssigned'/'cmActivity'
-- (and therefore 'available') are all zero is hidden entirely — it's
-- not carrying any money and has nothing left to clean up — but it
-- stays in @categoryMonths@ (built from *every* category, archived or
-- not) so invariant 1 keeps holding over the full ledger regardless of
-- what's currently on screen.
budgetTable :: [CategoryGroup] -> [Category] -> [CategoryMonth] -> Html ()
budgetTable groups categories categoryMonths = table_ $ do
  thead_ (tr_ (mapM_ (th_ . toHtml) (["Category", "Carried In", "Assigned", "Activity", "Available"] :: [Text])))
  tbody_ (mapM_ groupSection visibleGroups)
  where
    visibleGroups =
      [ (g, visibleRows)
      | g <- groups
      , let visibleRows = filter (isVisible categories) (rowsForGroup g)
      , not (null visibleRows)
      ]
    rowsForGroup g = [cm | cm <- categoryMonths, groupIdOf (cmCategory cm) == Just (cgId g)]
    groupIdOf cid = catGroupId <$> find ((== cid) . catId) categories

    groupSection :: (CategoryGroup, [CategoryMonth]) -> Html ()
    groupSection (g, rows) = do
      tr_ (th_ [colspan_ "5"] (toHtml (cgName g)))
      mapM_ (categoryMonthRow categories) rows

isVisible :: [Category] -> CategoryMonth -> Bool
isVisible categories cm = not (archived && allZero)
  where
    archived = maybe False isArchivedCategory (find ((== cmCategory cm) . catId) categories)
    allZero = cmCarriedIn cm == zeroCents && cmAssigned cm == zeroCents && cmActivity cm == zeroCents

categoryMonthRow :: [Category] -> CategoryMonth -> Html ()
categoryMonthRow categories cm = tr_ $ do
  td_ (toHtml (categoryNameFor categories (cmCategory cm)))
  td_ [class_ "amount"] (toHtml (centsToEuroText (cmCarriedIn cm)))
  td_ [class_ "amount"] (assignedCell cm)
  td_ [class_ "amount"] (toHtml (centsToEuroText (cmActivity cm)))
  td_ [class_ "amount"] (toHtml (centsToEuroText (available cm)))

-- | Inline click-to-edit "Assigned" amount (replacing the old detached
-- top-of-page assignment form): the Alpine @inlineAssign@ component
-- (@static/app.js@) shows the current value as plain text, reveals an
-- editable input on click, submits on Enter or on a real change
-- (blurring after actually typing something different), and Escape
-- restores the display value without a server round-trip. Without any
-- JS, this is still a perfectly ordinary @\<form\>@ — HTMX's
-- @hx-post@/@hx-target@/@hx-swap@ attributes stay on the form either
-- way, and implicit submission (Enter in the one text input) still
-- works.
assignedCell :: CategoryMonth -> Html ()
assignedCell cm =
  form_
    [ method_ "post"
    , action_ "/budget/assign"
    , hxPost_ "/budget/assign"
    , hxTarget_ "#budget-content"
    , hxSwap_ "outerHTML"
    , xData_ ("inlineAssign('" <> displayText <> "')")
    , xRef_ "form"
    ]
    $ do
      input_ [type_ "hidden", name_ "assignCategoryId", value_ (categoryIdText (cmCategory cm))]
      span_ [xShow_ "notEditing", xOn_ "click" "startEdit()", xText_ "displayValue"] (toHtml displayText)
      input_
        [ xShow_ "editing"
        , xRef_ "input"
        , type_ "text"
        , name_ "assignAmount"
        , xModel_ "value"
        , xOn_ "keydown.enter" "submitEdit()"
        , xOn_ "keydown.escape" "cancelEdit()"
        , xOn_ "change" "submitEdit()"
        ]
  where
    displayText = centsToEuroText (cmAssigned cm)

categoryNameFor :: [Category] -> CategoryId -> Text
categoryNameFor categories cid = case filter ((== cid) . catId) categories of
  (c : _) -> catName c
  []      -> "—"

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
