module Api.BudgetSpec (spec) where

import Api.Setup (postHtmlFormHx, withTestApp)
import qualified Data.ByteString.Lazy.Char8 as BSL8
import Data.Char (toLower)
import Data.List (isInfixOf)
import Network.Wai.Test (SResponse (simpleBody))
import Test.Hspec
import Test.Hspec.Wai

spec :: Spec
spec = with withTestApp $ do
  describe "GET /budget" $ do
    it "shows an empty budget as long as there are no categories" $ do
      response <- get "/budget"
      liftIO (bodyContains "Ready to Assign" response `shouldBe` True)

    it "is a full page linking the vendored static assets" $ do
      response <- get "/budget"
      liftIO (bodyContains "/static/pico.min.css" response `shouldBe` True)
      liftIO (bodyContainsCI "<!doctype html" response `shouldBe` True)

  describe "fragment vs. full page (S-1 fix)" $ do
    it "a plain (non-HTMX) POST gets a full page back (this used to always nest a full page inside the swap target)" $ do
      response <- postHtmlForm "/budget/assign" [("assignCategoryId", "999"), ("assignAmount", "50.00")]
      liftIO (bodyContainsCI "<!doctype html" response `shouldBe` True)
      liftIO (bodyContains "<nav" response `shouldBe` True)

    it "an HTMX POST (HX-Request: true) gets just the #budget-content fragment, not a nested page" $ do
      response <- postHtmlFormHx "/budget/assign" [("assignCategoryId", "999"), ("assignAmount", "50.00")]
      liftIO (bodyContainsCI "<!doctype html" response `shouldBe` False)
      liftIO (bodyContains "<nav" response `shouldBe` False)
      liftIO (bodyContains "Unknown category" response `shouldBe` True)

  describe "POST /budget/assign" $ do
    it "assigns money to a category and shows it in the table" $ do
      _ <- postHtmlForm "/category-groups" [("name", "Everyday Expenses")]
      _ <- postHtmlForm "/categories" [("categoryName", "Groceries"), ("groupId", "1")]
      response <- postHtmlForm "/budget/assign" [("assignCategoryId", "1"), ("assignAmount", "50.00")]
      liftIO (bodyContains "Groceries" response `shouldBe` True)
      liftIO (bodyContains "50.00" response `shouldBe` True)

    it "is an upsert: assigning again overwrites rather than adding a row" $ do
      _ <- postHtmlForm "/category-groups" [("name", "Everyday Expenses")]
      _ <- postHtmlForm "/categories" [("categoryName", "Groceries"), ("groupId", "1")]
      _ <- postHtmlForm "/budget/assign" [("assignCategoryId", "1"), ("assignAmount", "50.00")]
      response <- postHtmlForm "/budget/assign" [("assignCategoryId", "1"), ("assignAmount", "20.00")]
      liftIO (bodyContains "50.00" response `shouldBe` False)
      liftIO (bodyContains "20.00" response `shouldBe` True)

    it "rejects an unknown category with an error message, without adding a row" $ do
      response <- postHtmlForm "/budget/assign" [("assignCategoryId", "999"), ("assignAmount", "50.00")]
      liftIO (bodyContains "Unknown category" response `shouldBe` True)

    it "rejects an invalid amount with an error message, without adding a row" $ do
      _ <- postHtmlForm "/category-groups" [("name", "Everyday Expenses")]
      _ <- postHtmlForm "/categories" [("categoryName", "Groceries"), ("groupId", "1")]
      response <- postHtmlForm "/budget/assign" [("assignCategoryId", "1"), ("assignAmount", "not a number")]
      liftIO (bodyContains "Invalid amount" response `shouldBe` True)

bodyContains :: String -> SResponse -> Bool
bodyContains needle = (needle `isInfixOf`) . BSL8.unpack . simpleBody

-- | Case-insensitive: Lucid's exact casing for the doctype declaration
-- isn't a contract worth pinning a test to.
bodyContainsCI :: String -> SResponse -> Bool
bodyContainsCI needle = (map toLower needle `isInfixOf`) . map toLower . BSL8.unpack . simpleBody
