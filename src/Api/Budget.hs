-- | Routes and handlers for the monthly budget page: keep thin, HTTP
-- translation only (CLAUDE.md "Architecture") — the real logic already
-- lives in 'Db.Assignment'/'Domain.Budget'.
--
-- Shows whichever month @?month=YYYY-MM@ names (defaulting to today's
-- *local* calendar month, not UTC — see 'Api.Monad.localToday', Track A
-- Step 5, S-4), with its carry-in (both per-category and Ready to
-- Assign) folded forward from every earlier month with any activity via
-- 'Domain.Budget.rolloverMonths', instead of always starting at
-- 'zeroCents' (DECISIONS.md §8, H-5).
module Api.Budget
  ( BudgetApi
  , budgetServer
  ) where

import Data.Int (Int64)
import Data.List (find)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Read as TextRead
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
import Api.Monad (AppM, resolveViewedMonth, withConn)
import Api.Money (centsToEuroText, parseSignedEuros)
import qualified Db.Account as Db
import qualified Db.Assignment as Db
import qualified Db.Category as Db
import qualified Db.Transaction as Db
import Domain.Budget
  ( CategoryMonth (cmActivity, cmAssigned, cmCarriedIn, cmCategory)
  , MonthlyBudget (..)
  , available
  , budgetFor
  , monthsThrough
  , rolloverMonths
  )
import Domain.Category
  ( Category (catGroupId, catId, catName)
  , CategoryGroup (cgId, cgName)
  , isArchivedCategory
  )
import Domain.Types
  ( Cents
  , CategoryId (CategoryId)
  , YearMonth
  , nextYearMonth
  , prevYearMonth
  , yearMonthToText
  , zeroCents
  )
import Web.FormUrlEncoded (FromForm)

type BudgetApi =
  "budget" :> QueryParam "month" Text :> Get '[HTML] (Html ())
    :<|> Header "HX-Request" Text :> "budget" :> "assign" :> ReqBody '[FormUrlEncoded] NewAssignmentForm :> Post '[HTML] (Html ())

-- | Field names must match the @name@ attributes of 'assignedCell'
-- below — 'FromForm' parses by field name. @assignMonth@ (a hidden
-- field) carries whichever month is currently being viewed, so
-- assigning while browsing a past or future month doesn't silently
-- jump the page back to the current one.
data NewAssignmentForm = NewAssignmentForm
  { assignCategoryId :: Text
  , assignAmount     :: Text
  , assignMonth      :: Text
  }
  deriving stock (Generic)
  deriving anyclass (FromForm)

budgetServer :: ServerT BudgetApi AppM
budgetServer = listBudgetHandler :<|> assignHandler

listBudgetHandler :: Maybe Text -> AppM (Html ())
listBudgetHandler monthParam = do
  ym <- resolveViewedMonth monthParam
  renderFragment Nothing ym Nothing

-- | Assigning is signed on purpose (DECISIONS.md §12, Architect review
-- S-2): once money has rolled over into a category from a previous
-- month, the only way to move it back to Ready to Assign is setting
-- this month's assigned amount *negative* (e.g. @-50.00@ against a
-- carried-in €50) — 'Domain.Budget.available' already handles that
-- arithmetic correctly, the old unsigned-only parser was the only
-- thing stopping it from ever being reachable.
assignHandler :: Maybe Text -> NewAssignmentForm -> AppM (Html ())
assignHandler hx form = do
  ym <- resolveViewedMonth (Just (assignMonth form))
  case parseCategoryId (assignCategoryId form) of
    Nothing -> withError hx ym "Unknown category."
    Just cid -> case parseSignedEuros (assignAmount form) of
      Nothing -> withError hx ym "Invalid amount."
      Just amt -> do
        categories <- withConn Db.listCategories
        case find ((== cid) . catId) categories of
          Nothing -> withError hx ym "Unknown category."
          Just cat
            | isArchivedCategory cat -> withError hx ym "Cannot assign money to an archived category."
            | otherwise -> do
                withConn (\conn -> Db.setAssignment conn cid ym amt)
                renderFragment hx ym Nothing

withError :: Maybe Text -> YearMonth -> Text -> AppM (Html ())
withError hx ym msg = renderFragment hx ym (Just msg)

-- | Every mutating handler renders back through this. A plain
-- (non-HTMX) request gets a full page back — the progressive-
-- enhancement fallback for when HTMX didn't load — an HTMX request
-- gets just the @#budget-content@ fragment it's about to swap in
-- (hx-swap="outerHTML"); see 'Api.Html.pageOrFragment'.
renderFragment :: Maybe Text -> YearMonth -> Maybe Text -> AppM (Html ())
renderFragment hx ym err = do
  accounts <- withConn Db.listAccounts
  groups <- withConn Db.listCategoryGroups
  categories <- withConn Db.listCategories
  assignments <- withConn Db.listAllAssignments
  txs <- withConn Db.listAllTransactions
  let categoryIds = map catId categories
      months = monthsThrough ym assignments txs
      budgets = rolloverMonths accounts categoryIds months assignments txs
      viewedBudget = budgetFor ym budgets
  pure
    ( pageOrFragment
        hx
        "Budget"
        (budgetContent err ym groups categories (mbCategoryMonths viewedBudget) (mbReadyToAssign viewedBudget))
    )

budgetContent :: Maybe Text -> YearMonth -> [CategoryGroup] -> [Category] -> [CategoryMonth] -> Cents -> Html ()
budgetContent err ym groups categories categoryMonths rta = div_ [id_ "budget-content"] $ do
  errorBanner err
  monthNav ym
  readyToAssignBanner rta
  budgetTable ym groups categories categoryMonths

-- | @\<- Prev | YYYY-MM | Next -\>@, each a plain link to
-- @\/budget?month=YYYY-MM@ — no JS needed, and it degrades to normal
-- navigation with no HTMX involved at all (a full page load, still
-- correct). Deliberately a @\<ul\>@, not a @\<nav\>@: the latter is
-- already what 'Api.Html.page' uses for the site-wide header, and
-- tests tell a fragment from a full page by that element's absence —
-- a second, unrelated @\<nav\>@ here would defeat that check.
monthNav :: YearMonth -> Html ()
monthNav ym =
  ul_ [class_ "month-nav"] $ do
    li_ (a_ [href_ (monthLink (prevYearMonth ym))] "<- Prev")
    li_ (toHtml (yearMonthToText ym))
    li_ (a_ [href_ (monthLink (nextYearMonth ym))] "Next ->")
  where
    monthLink m = "/budget?month=" <> yearMonthToText m

readyToAssignBanner :: Cents -> Html ()
readyToAssignBanner rta = p_ (toHtml ("Ready to Assign: " <> centsToEuroText rta))

-- | Categories are grouped visually under their 'CategoryGroup'
-- heading instead of repeating the group name as a flat column. An
-- archived category whose 'cmCarriedIn'/'cmAssigned'/'cmActivity' (and
-- therefore 'available') are all zero is hidden entirely — it's not
-- carrying any money and has nothing left to clean up — but it stays
-- in @categoryMonths@ (built from *every* category, archived or not)
-- so invariant 1 keeps holding over the full ledger regardless of
-- what's currently on screen.
budgetTable :: YearMonth -> [CategoryGroup] -> [Category] -> [CategoryMonth] -> Html ()
budgetTable ym groups categories categoryMonths = table_ $ do
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
      mapM_ (categoryMonthRow ym categories) rows

isVisible :: [Category] -> CategoryMonth -> Bool
isVisible categories cm = not (archived && allZero)
  where
    archived = maybe False isArchivedCategory (find ((== cmCategory cm) . catId) categories)
    allZero = cmCarriedIn cm == zeroCents && cmAssigned cm == zeroCents && cmActivity cm == zeroCents

categoryMonthRow :: YearMonth -> [Category] -> CategoryMonth -> Html ()
categoryMonthRow ym categories cm = tr_ $ do
  td_ (toHtml (categoryNameFor categories (cmCategory cm)))
  td_ [class_ "amount"] (toHtml (centsToEuroText (cmCarriedIn cm)))
  td_ [class_ "amount"] (assignedCell ym cm)
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
-- works. The hidden @assignMonth@ field is what lets 'assignHandler'
-- assign into whichever month is currently being viewed, not always
-- the current one.
assignedCell :: YearMonth -> CategoryMonth -> Html ()
assignedCell ym cm =
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
      input_ [type_ "hidden", name_ "assignMonth", value_ (yearMonthToText ym)]
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
