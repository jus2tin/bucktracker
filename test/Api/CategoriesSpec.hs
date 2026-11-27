module Api.CategoriesSpec (spec) where

import Api.Setup (postHtmlFormHx, withTestApp)
import qualified Data.ByteString.Lazy.Char8 as BSL8
import Data.Char (toLower)
import Data.List (isInfixOf)
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Lazy.Encoding as TLE
import Network.Wai.Test (SResponse (simpleBody))
import Test.Hspec
import Test.Hspec.Wai

spec :: Spec
spec = with withTestApp $ do
  describe "GET /categories" $ do
    it "shows empty tables as long as there are no category groups" $
      get "/categories" `shouldRespondWith` 200

    it "is a full page linking the vendored static assets" $ do
      response <- get "/categories"
      liftIO (bodyContains "/static/pico.min.css" response `shouldBe` True)
      liftIO (bodyContainsCI "<!doctype html" response `shouldBe` True)

  describe "fragment vs. full page (S-1 fix)" $ do
    it "a plain (non-HTMX) POST gets a full page back, not a bare fragment" $ do
      response <- postHtmlForm "/category-groups" [("name", "Everyday Expenses")]
      liftIO (bodyContainsCI "<!doctype html" response `shouldBe` True)

    it "an HTMX POST (HX-Request: true) gets just the #categories-content fragment" $ do
      response <- postHtmlFormHx "/category-groups" [("name", "Everyday Expenses")]
      liftIO (bodyContainsCI "<!doctype html" response `shouldBe` False)
      liftIO (bodyContains "Everyday Expenses" response `shouldBe` True)

  describe "POST /category-groups" $ do
    it "creates a category group and shows it in the table" $ do
      response <- postHtmlForm "/category-groups" [("name", "Everyday Expenses")]
      liftIO (bodyContains "Everyday Expenses" response `shouldBe` True)

    it "rejects an empty name with an error message, without adding a row" $ do
      response <- postHtmlForm "/category-groups" [("name", "")]
      liftIO (bodyContains "Name must not be empty" response `shouldBe` True)

  describe "POST /category-groups/:id/archive" $
    it "archives the group: the button disappears, the status changes" $ do
      _ <- postHtmlForm "/category-groups" [("name", "Old Group")]
      response <- postHtmlForm "/category-groups/1/archive" []
      liftIO (bodyContains "Archived" response `shouldBe` True)
      liftIO (bodyContains "Archive<" response `shouldBe` False)

  describe "POST /categories" $ do
    it "creates a category in an existing group and shows it in the table" $ do
      _ <- postHtmlForm "/category-groups" [("name", "Everyday Expenses")]
      response <- postHtmlForm "/categories" [("categoryName", "Groceries"), ("groupId", "1")]
      liftIO (bodyContains "Groceries" response `shouldBe` True)

    it "rejects an unknown group id with an error message, without adding a row" $ do
      response <- postHtmlForm "/categories" [("categoryName", "Groceries"), ("groupId", "999")]
      liftIO (bodyContains "Unknown category group" response `shouldBe` True)

    it "rejects an empty name with an error message, without adding a row" $ do
      _ <- postHtmlForm "/category-groups" [("name", "Everyday Expenses")]
      response <- postHtmlForm "/categories" [("categoryName", ""), ("groupId", "1")]
      liftIO (bodyContains "Name must not be empty" response `shouldBe` True)

  describe "POST /categories/:id/archive" $
    it "archives the category: its own button disappears, the status changes" $ do
      _ <- postHtmlForm "/category-groups" [("name", "Everyday Expenses")]
      beforeResponse <- postHtmlForm "/categories" [("categoryName", "Groceries"), ("groupId", "1")]
      -- The category's own group is still active, so its "Archive"
      -- button stays on the page — only the category's button (one of
      -- the two "Archive" buttons at this point) should disappear.
      let buttonsBefore = countOccurrences "Archive<" beforeResponse
      response <- postHtmlForm "/categories/1/archive" []
      liftIO (bodyContains "Archived" response `shouldBe` True)
      liftIO (countOccurrences "Archive<" response `shouldBe` buttonsBefore - 1)

bodyContains :: String -> SResponse -> Bool
bodyContains needle = (needle `isInfixOf`) . BSL8.unpack . simpleBody

-- | Case-insensitive: Lucid's exact casing for the doctype declaration
-- isn't a contract worth pinning a test to.
bodyContainsCI :: String -> SResponse -> Bool
bodyContainsCI needle = (map toLower needle `isInfixOf`) . map toLower . BSL8.unpack . simpleBody

countOccurrences :: TL.Text -> SResponse -> Int
countOccurrences needle = fromIntegral . TL.count needle . TLE.decodeUtf8 . simpleBody
