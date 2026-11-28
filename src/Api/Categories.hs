-- | Routes and handlers for category groups and categories: keep thin,
-- HTTP translation only (CLAUDE.md "Architecture") — the real logic
-- already lives in 'Db.Category'/'Domain.Category'.
module Api.Categories
  ( CategoriesApi
  , categoriesServer
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

import Api.Html (errorBanner, hxConfirm_, hxPost_, hxSwap_, hxTarget_, pageOrFragment)
import Api.Monad (AppM, localToday, withConn)
import qualified Db.Account as Db
import qualified Db.Assignment as Db
import qualified Db.Category as Db
import qualified Db.Transaction as Db
import Domain.Budget
  ( CategoryMonth (cmCategory)
  , MonthlyBudget (mbCategoryMonths, mbMonth)
  , available
  , monthsThrough
  , rolloverMonths
  )
import Domain.Category
  ( Category (catGroupId, catId, catName)
  , CategoryGroup (cgId, cgName)
  , isArchivedCategory
  , isArchivedGroup
  )
import Domain.Error (DomainError (..))
import Domain.Types (CategoryGroupId (CategoryGroupId), CategoryId (CategoryId), Cents, dayToYearMonth, zeroCents)
import Web.FormUrlEncoded (FromForm)

type CategoriesApi =
  "categories" :> Get '[HTML] (Html ())
    :<|> Header "HX-Request" Text :> "category-groups" :> ReqBody '[FormUrlEncoded] NewCategoryGroupForm :> Post '[HTML] (Html ())
    :<|> Header "HX-Request" Text :> "category-groups" :> Capture "id" Int64 :> "archive" :> Post '[HTML] (Html ())
    :<|> Header "HX-Request" Text :> "category-groups" :> Capture "id" Int64 :> "unarchive" :> Post '[HTML] (Html ())
    :<|> Header "HX-Request" Text :> "categories" :> ReqBody '[FormUrlEncoded] NewCategoryForm :> Post '[HTML] (Html ())
    :<|> Header "HX-Request" Text :> "categories" :> Capture "id" Int64 :> "archive" :> Post '[HTML] (Html ())
    :<|> Header "HX-Request" Text :> "categories" :> Capture "id" Int64 :> "unarchive" :> Post '[HTML] (Html ())

newtype NewCategoryGroupForm = NewCategoryGroupForm
  { name :: Text
  }
  deriving stock (Generic)
  deriving anyclass (FromForm)

-- | Field names must match the @name@ attributes of 'newCategoryForm'
-- below — 'FromForm' parses by field name. ('name' is already taken by
-- 'NewCategoryGroupForm' in this module — no 'DuplicateRecordFields'.)
data NewCategoryForm = NewCategoryForm
  { categoryName :: Text
  , groupId      :: Text
  }
  deriving stock (Generic)
  deriving anyclass (FromForm)

categoriesServer :: ServerT CategoriesApi AppM
categoriesServer =
  listCategoriesHandler
    :<|> createCategoryGroupHandler
    :<|> archiveCategoryGroupHandler
    :<|> unarchiveCategoryGroupHandler
    :<|> createCategoryHandler
    :<|> archiveCategoryHandler
    :<|> unarchiveCategoryHandler

listCategoriesHandler :: AppM (Html ())
listCategoriesHandler = renderFragment Nothing Nothing

createCategoryGroupHandler :: Maybe Text -> NewCategoryGroupForm -> AppM (Html ())
createCategoryGroupHandler hx form = do
  result <- withConn (\conn -> Db.insertCategoryGroup conn (name form))
  case result of
    Left (EmptyName _) -> withError hx "Name must not be empty."
    Left _ -> withError hx "Could not create category group."
    Right _ -> renderFragment hx Nothing

-- | Blocks archiving a group that still has active (non-archived)
-- categories in it (DECISIONS.md §11): otherwise those categories would
-- stay reachable from the budget/spending pages while their own parent
-- group vanished from the "add category" picker, with no way back to
-- it except archiving every category individually first anyway — this
-- just makes that ordering explicit instead of a confusing dead end. A
-- no-op (not an error) on an unknown id, consistent with the Db layer.
archiveCategoryGroupHandler :: Maybe Text -> Int64 -> AppM (Html ())
archiveCategoryGroupHandler hx rawId = do
  let gid = CategoryGroupId rawId
  categories <- withConn Db.listCategories
  if any (\c -> catGroupId c == gid && not (isArchivedCategory c)) categories
    then withError hx "Cannot archive a group that still has active categories."
    else do
      withConn (\conn -> Db.archiveCategoryGroup conn gid)
      renderFragment hx Nothing

unarchiveCategoryGroupHandler :: Maybe Text -> Int64 -> AppM (Html ())
unarchiveCategoryGroupHandler hx rawId = do
  withConn (\conn -> Db.unarchiveCategoryGroup conn (CategoryGroupId rawId))
  renderFragment hx Nothing

createCategoryHandler :: Maybe Text -> NewCategoryForm -> AppM (Html ())
createCategoryHandler hx form = case parseCategoryGroupId (groupId form) of
  Nothing -> withError hx "Unknown category group."
  Just gid -> do
    groups <- withConn Db.listCategoryGroups
    if any ((== gid) . cgId) groups
      then do
        result <- withConn (\conn -> Db.insertCategory conn gid (categoryName form))
        case result of
          Left (EmptyName _) -> withError hx "Name must not be empty."
          Left ArchivedCategoryGroup -> withError hx "Cannot add a category to an archived group."
          Left _ -> withError hx "Could not create category."
          Right _ -> renderFragment hx Nothing
      else withError hx "Unknown category group."

-- | Blocks archiving a category that still carries a non-zero balance
-- in today's local month *or any later one already on the books*
-- (DECISIONS.md §11, AUDIT-04) — mirrors
-- 'Api.Accounts.archiveAccountHandler'. Checking only today's month
-- would have let a category with €0 available now but, say, €400
-- already assigned next month be archived — stranding that €400, since
-- 'Api.Budget.assignHandler' then refuses to touch an archived
-- category at all. A no-op (not an error) on an unknown id, consistent
-- with the Db layer.
archiveCategoryHandler :: Maybe Text -> Int64 -> AppM (Html ())
archiveCategoryHandler hx rawId = do
  let cid = CategoryId rawId
  categories <- withConn Db.listCategories
  case find ((== cid) . catId) categories of
    Nothing -> renderFragment hx Nothing
    Just _ -> do
      nonZero <- hasNonZeroBalanceFromNowOn cid
      if nonZero
        then withError hx "Cannot archive a category with a non-zero balance now or in a later month."
        else do
          withConn (\conn -> Db.archiveCategory conn cid)
          renderFragment hx Nothing

unarchiveCategoryHandler :: Maybe Text -> Int64 -> AppM (Html ())
unarchiveCategoryHandler hx rawId = do
  withConn (\conn -> Db.unarchiveCategory conn (CategoryId rawId))
  renderFragment hx Nothing

-- | Whether a category's 'Domain.Budget.available' balance is non-zero
-- in today's local month or in any later month already reachable via
-- @?month=@ (anything in 'monthsThrough's range) — folding the full
-- rollover history forward exactly like 'Api.Budget.renderFragment'
-- does for the page the user actually sees, just checked across every
-- month from now on instead of only the one currently viewed.
hasNonZeroBalanceFromNowOn :: CategoryId -> AppM Bool
hasNonZeroBalanceFromNowOn cid = do
  today <- localToday
  let ym = dayToYearMonth today
  accounts <- withConn Db.listAccounts
  categories <- withConn Db.listCategories
  assignments <- withConn Db.listAllAssignments
  txs <- withConn Db.listAllTransactions
  let categoryIds = map catId categories
      months = monthsThrough ym assignments txs
      budgets = rolloverMonths accounts categoryIds months assignments txs
      fromNowOn = filter ((>= ym) . mbMonth) budgets
      balanceIn mb = maybe zeroCents available (find ((== cid) . cmCategory) (mbCategoryMonths mb))
  pure (any ((/= zeroCents) . balanceIn) fromNowOn)

withError :: Maybe Text -> Text -> AppM (Html ())
withError hx msg = renderFragment hx (Just msg)

-- | Every mutating handler renders back through this. A plain
-- (non-HTMX) request gets a full page back — the progressive-
-- enhancement fallback for when HTMX didn't load — an HTMX request
-- gets just the @#categories-content@ fragment it's about to swap in
-- (hx-swap="outerHTML"); see 'Api.Html.pageOrFragment'.
renderFragment :: Maybe Text -> Maybe Text -> AppM (Html ())
renderFragment hx err = do
  groups <- withConn Db.listCategoryGroups
  categories <- withConn Db.listCategories
  pure (pageOrFragment hx "Categories" (categoriesContent err groups categories))

categoriesContent :: Maybe Text -> [CategoryGroup] -> [Category] -> Html ()
categoriesContent err groups categories = div_ [id_ "categories-content"] $ do
  errorBanner err
  newCategoryGroupForm
  categoryGroupsTable groups
  newCategoryForm groups
  categoriesTable groups categories
  onboardingBanner groups categories

-- | Shown instead of a bare, empty table the very first time Bucktracker
-- is opened (Track A Step 6) — see 'Api.Accounts.onboardingBanner'.
onboardingBanner :: [CategoryGroup] -> [Category] -> Html ()
onboardingBanner [] _ = p_ "No category groups yet — add one above, then add categories to it below."
onboardingBanner _ [] = p_ "No categories yet — add one below, in whichever group it belongs to."
onboardingBanner _ _  = mempty

newCategoryGroupForm :: Html ()
newCategoryGroupForm =
  form_
    [ method_ "post"
    , action_ "/category-groups"
    , hxPost_ "/category-groups"
    , hxTarget_ "#categories-content"
    , hxSwap_ "outerHTML"
    ]
    $ do
      input_ [type_ "text", name_ "name", placeholder_ "Group name"]
      button_ [type_ "submit"] "Add group"

categoryGroupsTable :: [CategoryGroup] -> Html ()
categoryGroupsTable groups = table_ $ do
  thead_ (tr_ (mapM_ (th_ . toHtml) (["Group", "Status", ""] :: [Text])))
  tbody_ (mapM_ categoryGroupRow groups)

categoryGroupRow :: CategoryGroup -> Html ()
categoryGroupRow cg = tr_ $ do
  td_ (toHtml (cgName cg))
  td_ (toHtml (statusText (isArchivedGroup cg)))
  td_ (archiveGroupToggleButton cg)

-- | Toggles between "Archive" and "Unarchive" — see
-- 'Api.Accounts.archiveToggleButton'.
archiveGroupToggleButton :: CategoryGroup -> Html ()
archiveGroupToggleButton cg
  | isArchivedGroup cg =
      let routePath = "/category-groups/" <> categoryGroupIdText (cgId cg) <> "/unarchive"
      in form_ [method_ "post", action_ routePath] $
           button_
             [type_ "submit", hxPost_ routePath, hxTarget_ "#categories-content", hxSwap_ "outerHTML"]
             "Unarchive"
  | otherwise =
      let routePath = "/category-groups/" <> categoryGroupIdText (cgId cg) <> "/archive"
      in form_ [method_ "post", action_ routePath] $
           button_
             [ type_ "submit"
             , hxPost_ routePath
             , hxTarget_ "#categories-content"
             , hxSwap_ "outerHTML"
             , hxConfirm_ "Archive this category group?"
             ]
             "Archive"

newCategoryForm :: [CategoryGroup] -> Html ()
newCategoryForm groups =
  form_ [method_ "post", action_ "/categories", hxPost_ "/categories", hxTarget_ "#categories-content", hxSwap_ "outerHTML"] $ do
    input_ [type_ "text", name_ "categoryName", placeholder_ "Category name"]
    select_ [name_ "groupId"] (mapM_ groupOption (filter (not . isArchivedGroup) groups))
    button_ [type_ "submit"] "Add category"

groupOption :: CategoryGroup -> Html ()
groupOption cg = option_ [value_ (categoryGroupIdText (cgId cg))] (toHtml (cgName cg))

categoriesTable :: [CategoryGroup] -> [Category] -> Html ()
categoriesTable groups categories = table_ $ do
  thead_ (tr_ (mapM_ (th_ . toHtml) (["Category", "Group", "Status", ""] :: [Text])))
  tbody_ (mapM_ (categoryRow groups) categories)

categoryRow :: [CategoryGroup] -> Category -> Html ()
categoryRow groups cat = tr_ $ do
  td_ (toHtml (catName cat))
  td_ (toHtml (groupNameFor groups (catGroupId cat)))
  td_ (toHtml (statusText (isArchivedCategory cat)))
  td_ (archiveCategoryToggleButton cat)

groupNameFor :: [CategoryGroup] -> CategoryGroupId -> Text
groupNameFor groups gid = case filter ((== gid) . cgId) groups of
  (cg : _) -> cgName cg
  []       -> "—"

-- | Toggles between "Archive" and "Unarchive" — see
-- 'Api.Accounts.archiveToggleButton'.
archiveCategoryToggleButton :: Category -> Html ()
archiveCategoryToggleButton cat
  | isArchivedCategory cat =
      let routePath = "/categories/" <> categoryIdText (catId cat) <> "/unarchive"
      in form_ [method_ "post", action_ routePath] $
           button_
             [type_ "submit", hxPost_ routePath, hxTarget_ "#categories-content", hxSwap_ "outerHTML"]
             "Unarchive"
  | otherwise =
      let routePath = "/categories/" <> categoryIdText (catId cat) <> "/archive"
      in form_ [method_ "post", action_ routePath] $
           button_
             [ type_ "submit"
             , hxPost_ routePath
             , hxTarget_ "#categories-content"
             , hxSwap_ "outerHTML"
             , hxConfirm_ "Archive this category?"
             ]
             "Archive"

statusText :: Bool -> Text
statusText archived = if archived then "Archived" else "Active"

categoryGroupIdText :: CategoryGroupId -> Text
categoryGroupIdText (CategoryGroupId i) = Text.pack (show i)

categoryIdText :: CategoryId -> Text
categoryIdText (CategoryId i) = Text.pack (show i)

-- | Parses a decimal id out of an HTML @\<select\>@'s value, total and
-- without 'Prelude.read' (CLAUDE.md "Total functions only").
parseCategoryGroupId :: Text -> Maybe CategoryGroupId
parseCategoryGroupId t = case TextRead.decimal t of
  Right (n, rest) | Text.null rest -> Just (CategoryGroupId n)
  _                                -> Nothing
