-- | Routes and handlers for category groups and categories: keep thin,
-- HTTP translation only (CLAUDE.md "Architecture") — the real logic
-- already lives in 'Db.Category'/'Domain.Category'.
module Api.Categories
  ( CategoriesApi
  , categoriesServer
  ) where

import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Read as TextRead
import GHC.Generics (Generic)
import Lucid
import Servant
import Servant.HTML.Lucid (HTML)

import Api.Html (errorBanner, hxPost_, hxSwap_, hxTarget_, pageOrFragment)
import Api.Monad (AppM, withConn)
import qualified Db.Category as Db
import Domain.Category
  ( Category (catGroupId, catId, catName)
  , CategoryGroup (cgId, cgName)
  , isArchivedCategory
  , isArchivedGroup
  )
import Domain.Error (DomainError (EmptyName))
import Domain.Types (CategoryGroupId (CategoryGroupId), CategoryId (CategoryId))
import Web.FormUrlEncoded (FromForm)

type CategoriesApi =
  "categories" :> Get '[HTML] (Html ())
    :<|> Header "HX-Request" Text :> "category-groups" :> ReqBody '[FormUrlEncoded] NewCategoryGroupForm :> Post '[HTML] (Html ())
    :<|> Header "HX-Request" Text :> "category-groups" :> Capture "id" Int64 :> "archive" :> Post '[HTML] (Html ())
    :<|> Header "HX-Request" Text :> "categories" :> ReqBody '[FormUrlEncoded] NewCategoryForm :> Post '[HTML] (Html ())
    :<|> Header "HX-Request" Text :> "categories" :> Capture "id" Int64 :> "archive" :> Post '[HTML] (Html ())

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
    :<|> createCategoryHandler
    :<|> archiveCategoryHandler

listCategoriesHandler :: AppM (Html ())
listCategoriesHandler = renderFragment Nothing Nothing

createCategoryGroupHandler :: Maybe Text -> NewCategoryGroupForm -> AppM (Html ())
createCategoryGroupHandler hx form = do
  result <- withConn (\conn -> Db.insertCategoryGroup conn (name form))
  case result of
    Left (EmptyName _) -> withError hx "Name must not be empty."
    Left _ -> withError hx "Could not create category group."
    Right _ -> renderFragment hx Nothing

archiveCategoryGroupHandler :: Maybe Text -> Int64 -> AppM (Html ())
archiveCategoryGroupHandler hx rawId = do
  withConn (\conn -> Db.archiveCategoryGroup conn (CategoryGroupId rawId))
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
          Left _ -> withError hx "Could not create category."
          Right _ -> renderFragment hx Nothing
      else withError hx "Unknown category group."

archiveCategoryHandler :: Maybe Text -> Int64 -> AppM (Html ())
archiveCategoryHandler hx rawId = do
  withConn (\conn -> Db.archiveCategory conn (CategoryId rawId))
  renderFragment hx Nothing

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
  td_ (archiveGroupButton cg)

archiveGroupButton :: CategoryGroup -> Html ()
archiveGroupButton cg
  | isArchivedGroup cg = mempty
  | otherwise =
      let routePath = "/category-groups/" <> categoryGroupIdText (cgId cg) <> "/archive"
      in form_ [method_ "post", action_ routePath] $
           button_
             [type_ "submit", hxPost_ routePath, hxTarget_ "#categories-content", hxSwap_ "outerHTML"]
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
  td_ (archiveCategoryButton cat)

groupNameFor :: [CategoryGroup] -> CategoryGroupId -> Text
groupNameFor groups gid = case filter ((== gid) . cgId) groups of
  (cg : _) -> cgName cg
  []       -> "—"

archiveCategoryButton :: Category -> Html ()
archiveCategoryButton cat
  | isArchivedCategory cat = mempty
  | otherwise =
      let routePath = "/categories/" <> categoryIdText (catId cat) <> "/archive"
      in form_ [method_ "post", action_ routePath] $
           button_
             [type_ "submit", hxPost_ routePath, hxTarget_ "#categories-content", hxSwap_ "outerHTML"]
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
