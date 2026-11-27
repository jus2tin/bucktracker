module Api.BudgetSpec (spec) where

import Api.Setup (withTestApp)
import qualified Data.ByteString.Lazy.Char8 as BSL8
import Data.List (isInfixOf)
import Network.Wai.Test (SResponse (simpleBody))
import Test.Hspec
import Test.Hspec.Wai

spec :: Spec
spec = with withTestApp $ do
  describe "GET /budget" $
    it "shows an empty budget as long as there are no categories" $ do
      response <- get "/budget"
      liftIO (bodyContains "Ready to Assign" response `shouldBe` True)

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
