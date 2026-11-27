module Api.AccountsSpec (spec) where

import Api.Setup (withTestApp)
import qualified Data.ByteString.Lazy.Char8 as BSL8
import Data.List (isInfixOf)
import Data.Time (getCurrentTime, showGregorian, utctDay)
import Network.HTTP.Types (hLocation)
import Network.Wai.Test (SResponse (simpleBody, simpleHeaders))
import Test.Hspec
import Test.Hspec.Wai

spec :: Spec
spec = with withTestApp $ do
  describe "GET /" $
    it "redirects to /budget" $ do
      response <- get "/"
      liftIO (response `shouldSatisfy` ((== Just "/budget") . lookup hLocation . simpleHeaders))

  describe "GET /accounts" $
    it "shows an empty table as long as there are no accounts" $
      get "/accounts" `shouldRespondWith` 200

  describe "POST /accounts" $ do
    it "creates an account and shows it in the table" $ do
      response <- postHtmlForm "/accounts" [("name", "Checking Account"), ("accountType", "checking")]
      liftIO (bodyContains "Checking Account" response `shouldBe` True)

    it "rejects an empty name with an error message, without adding a row" $ do
      response <- postHtmlForm "/accounts" [("name", ""), ("accountType", "checking")]
      liftIO (bodyContains "Name must not be empty" response `shouldBe` True)

  describe "POST /accounts/:id/archive" $
    it "archives the account: the button disappears, the status changes" $ do
      _ <- postHtmlForm "/accounts" [("name", "Old Account"), ("accountType", "cash")]
      response <- postHtmlForm "/accounts/1/archive" []
      liftIO (bodyContains "Archived" response `shouldBe` True)
      liftIO (bodyContains "Archive<" response `shouldBe` False)

  describe "GET /accounts (balance column)" $
    it "shows an account's running balance, not just its name/type/status" $ do
      _ <- postHtmlForm "/accounts" [("name", "Checking Account"), ("accountType", "checking")]
      today <- liftIO (showGregorian . utctDay <$> getCurrentTime)
      response <-
        postHtmlForm
          "/transactions/inflow"
          [("inflowAccountId", "1"), ("inflowDate", today), ("inflowPayee", "Salary"), ("inflowAmount", "123.45")]
      liftIO (bodyContains "123.45" response `shouldBe` True) -- sanity: the inflow itself was accepted
      accountsPage <- get "/accounts"
      liftIO (bodyContains "123.45" accountsPage `shouldBe` True)

  describe "POST /accounts/:id/reconcile" $ do
    it "reconciles when the statement balance matches the cleared balance" $ do
      _ <- postHtmlForm "/accounts" [("name", "Checking"), ("accountType", "checking")]
      today <- liftIO (showGregorian . utctDay <$> getCurrentTime)
      _ <-
        postHtmlForm
          "/transactions/inflow"
          [("inflowAccountId", "1"), ("inflowDate", today), ("inflowPayee", "Salary"), ("inflowAmount", "100.00")]
      _ <- postHtmlForm "/transactions/1/clear" []
      response <- postHtmlForm "/accounts/1/reconcile" [("statementBalance", "100.00")]
      liftIO (bodyContains "reconciled" response `shouldBe` True)
      -- the actual status change lives on the Transactions page, not Accounts
      transactionsPage <- get "/transactions"
      liftIO (bodyContains "reconciled" transactionsPage `shouldBe` True)

    it "rejects a mismatched statement balance, without changing anything" $ do
      _ <- postHtmlForm "/accounts" [("name", "Checking"), ("accountType", "checking")]
      today <- liftIO (showGregorian . utctDay <$> getCurrentTime)
      _ <-
        postHtmlForm
          "/transactions/inflow"
          [("inflowAccountId", "1"), ("inflowDate", today), ("inflowPayee", "Salary"), ("inflowAmount", "100.00")]
      _ <- postHtmlForm "/transactions/1/clear" []
      response <- postHtmlForm "/accounts/1/reconcile" [("statementBalance", "999.00")]
      -- not "Doesn't match": Lucid HTML-escapes the apostrophe, so the
      -- raw string wouldn't be found verbatim in the response body
      liftIO (bodyContains "Nothing was changed" response `shouldBe` True)
      transactionsPage <- get "/transactions"
      liftIO (bodyContains "reconciled" transactionsPage `shouldBe` False)

    it "rejects an unknown account, without creating or changing anything" $ do
      response <- postHtmlForm "/accounts/999/reconcile" [("statementBalance", "0.00")]
      liftIO (bodyContains "Unknown account" response `shouldBe` True)

bodyContains :: String -> SResponse -> Bool
bodyContains needle = (needle `isInfixOf`) . BSL8.unpack . simpleBody
