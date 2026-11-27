module Api.TransactionsSpec (spec) where

import Api.Setup (postHtmlFormHx, withTestApp)
import qualified Data.ByteString.Lazy.Char8 as BSL8
import Data.Char (toLower)
import Data.List (isInfixOf)
import Data.Time (getCurrentTime, showGregorian, utctDay)
import Network.Wai.Test (SResponse (simpleBody))
import Test.Hspec
import Test.Hspec.Wai

-- | The register only ever shows the current calendar month (no month
-- picker yet, see Api.Transactions) — tests therefore post transactions
-- dated today rather than a fixed date, so they keep passing regardless
-- of when they're run.
today :: IO String
today = showGregorian . utctDay <$> getCurrentTime

spec :: Spec
spec = with withTestApp $ do
  describe "GET /transactions" $ do
    it "shows an empty register as long as there are no transactions" $
      get "/transactions" `shouldRespondWith` 200

    it "is a full page linking the vendored static assets" $ do
      response <- get "/transactions"
      liftIO (bodyContains "/static/pico.min.css" response `shouldBe` True)
      liftIO (bodyContainsCI "<!doctype html" response `shouldBe` True)

  describe "fragment vs. full page (S-1 fix)" $ do
    it "a plain (non-HTMX) POST gets a full page back, not a bare fragment (this used to always nest a full page inside the swap target)" $ do
      day <- liftIO today
      response <-
        postHtmlForm
          "/transactions/inflow"
          [("inflowAccountId", "999"), ("inflowDate", day), ("inflowPayee", "Salary"), ("inflowAmount", "1")]
      liftIO (bodyContainsCI "<!doctype html" response `shouldBe` True)
      liftIO (bodyContains "<nav" response `shouldBe` True)

    it "an HTMX POST (HX-Request: true) gets just the #transactions-content fragment, not a nested page" $ do
      day <- liftIO today
      response <-
        postHtmlFormHx
          "/transactions/inflow"
          [("inflowAccountId", "999"), ("inflowDate", day), ("inflowPayee", "Salary"), ("inflowAmount", "1")]
      liftIO (bodyContainsCI "<!doctype html" response `shouldBe` False)
      liftIO (bodyContains "<nav" response `shouldBe` False)
      liftIO (bodyContains "Unknown account" response `shouldBe` True)

  describe "POST /transactions/inflow" $ do
    it "creates an inflow transaction and shows it in the register" $ do
      _ <- postHtmlForm "/accounts" [("name", "Checking"), ("accountType", "checking")]
      day <- liftIO today
      response <-
        postHtmlForm
          "/transactions/inflow"
          [("inflowAccountId", "1"), ("inflowDate", day), ("inflowPayee", "Salary"), ("inflowAmount", "123.45")]
      liftIO (bodyContains "Salary" response `shouldBe` True)
      liftIO (bodyContains "123.45" response `shouldBe` True)
      liftIO (bodyContains "Ready to Assign" response `shouldBe` True)

    it "rejects an unknown account with an error message, without adding a row" $ do
      day <- liftIO today
      response <-
        postHtmlForm
          "/transactions/inflow"
          [("inflowAccountId", "999"), ("inflowDate", day), ("inflowPayee", "Salary"), ("inflowAmount", "1")]
      liftIO (bodyContains "Unknown account" response `shouldBe` True)

    it "rejects an invalid amount with an error message, without adding a row" $ do
      _ <- postHtmlForm "/accounts" [("name", "Checking"), ("accountType", "checking")]
      day <- liftIO today
      response <-
        postHtmlForm
          "/transactions/inflow"
          [("inflowAccountId", "1"), ("inflowDate", day), ("inflowPayee", "Salary"), ("inflowAmount", "not a number")]
      liftIO (bodyContains "Invalid amount" response `shouldBe` True)

  describe "POST /transactions/spending" $ do
    it "creates a categorized expense and shows it in the register, stored as negative" $ do
      _ <- postHtmlForm "/accounts" [("name", "Checking"), ("accountType", "checking")]
      _ <- postHtmlForm "/category-groups" [("name", "Everyday Expenses")]
      _ <- postHtmlForm "/categories" [("categoryName", "Groceries"), ("groupId", "1")]
      day <- liftIO today
      response <- postHtmlForm "/transactions/spending" (singleLineSpending day "1" "1" "12.34")
      liftIO (bodyContains "Supermarket" response `shouldBe` True)
      liftIO (bodyContains "Groceries" response `shouldBe` True)
      liftIO (bodyContains "-12.34" response `shouldBe` True)

    it "splits an expense across two categories, both shown and summing to the total" $ do
      _ <- postHtmlForm "/accounts" [("name", "Checking"), ("accountType", "checking")]
      _ <- postHtmlForm "/category-groups" [("name", "Everyday Expenses")]
      _ <- postHtmlForm "/categories" [("categoryName", "Groceries"), ("groupId", "1")]
      _ <- postHtmlForm "/categories" [("categoryName", "Household"), ("groupId", "1")]
      day <- liftIO today
      response <-
        postHtmlForm
          "/transactions/spending"
          [ ("spendingAccountId", "1")
          , ("spendingDate", day)
          , ("spendingPayee", "Supermarket")
          , ("spendingCategoryId1", "1")
          , ("spendingAmount1", "40.00")
          , ("spendingCategoryId2", "2")
          , ("spendingAmount2", "24.30")
          , ("spendingCategoryId3", "")
          , ("spendingAmount3", "")
          ]
      liftIO (bodyContains "Groceries, Household" response `shouldBe` True)
      liftIO (bodyContains "-64.30" response `shouldBe` True) -- 40.00 + 24.30, derived, not stored separately

    it "rejects a categorized expense on a tracking account" $ do
      _ <- postHtmlForm "/accounts" [("name", "Investments"), ("accountType", "tracking")]
      _ <- postHtmlForm "/category-groups" [("name", "Everyday Expenses")]
      _ <- postHtmlForm "/categories" [("categoryName", "Groceries"), ("groupId", "1")]
      day <- liftIO today
      response <- postHtmlForm "/transactions/spending" (singleLineSpending day "1" "1" "12.34")
      liftIO (bodyContains "not allowed on tracking accounts" response `shouldBe` True)

    it "rejects an unknown category with an error message, without adding a row" $ do
      _ <- postHtmlForm "/accounts" [("name", "Checking"), ("accountType", "checking")]
      day <- liftIO today
      response <- postHtmlForm "/transactions/spending" (singleLineSpending day "1" "999" "12.34")
      liftIO (bodyContains "Unknown category" response `shouldBe` True)

  describe "POST /transactions/transfer" $ do
    it "creates both legs of a transfer and shows them in the register" $ do
      _ <- postHtmlForm "/accounts" [("name", "Checking"), ("accountType", "checking")]
      _ <- postHtmlForm "/accounts" [("name", "Savings"), ("accountType", "savings")]
      day <- liftIO today
      response <-
        postHtmlForm
          "/transactions/transfer"
          [("transferFromAccountId", "1"), ("transferToAccountId", "2"), ("transferDate", day), ("transferAmount", "50.00")]
      liftIO (bodyContains "Transfer: Savings" response `shouldBe` True)
      liftIO (bodyContains "Transfer: Checking" response `shouldBe` True)

    it "rejects a transfer to the same account" $ do
      _ <- postHtmlForm "/accounts" [("name", "Checking"), ("accountType", "checking")]
      day <- liftIO today
      response <-
        postHtmlForm
          "/transactions/transfer"
          [("transferFromAccountId", "1"), ("transferToAccountId", "1"), ("transferDate", day), ("transferAmount", "50.00")]
      liftIO (bodyContains "two different accounts" response `shouldBe` True)

    it "rejects a transfer between an on-budget and a tracking account" $ do
      _ <- postHtmlForm "/accounts" [("name", "Checking"), ("accountType", "checking")]
      _ <- postHtmlForm "/accounts" [("name", "Investments"), ("accountType", "tracking")]
      day <- liftIO today
      response <-
        postHtmlForm
          "/transactions/transfer"
          [("transferFromAccountId", "1"), ("transferToAccountId", "2"), ("transferDate", day), ("transferAmount", "50.00")]
      liftIO (bodyContains "tracking account" response `shouldBe` True)

  describe "POST /transactions/:id/clear" $
    it "toggles a transaction between Uncleared and Cleared (the first step of reconciling)" $ do
      _ <- postHtmlForm "/accounts" [("name", "Checking"), ("accountType", "checking")]
      day <- liftIO today
      _ <-
        postHtmlForm
          "/transactions/inflow"
          [("inflowAccountId", "1"), ("inflowDate", day), ("inflowPayee", "Salary"), ("inflowAmount", "100.00")]
      beforeToggle <- get "/transactions"
      liftIO (bodyContains "uncleared" beforeToggle `shouldBe` True)

      -- "uncleared" is a superstring of "cleared", so absence of
      -- "uncleared" (not presence of "cleared") is the real assertion.
      afterFirstToggle <- postHtmlForm "/transactions/1/clear" []
      liftIO (bodyContains "uncleared" afterFirstToggle `shouldBe` False)

      afterSecondToggle <- postHtmlForm "/transactions/1/clear" []
      liftIO (bodyContains "uncleared" afterSecondToggle `shouldBe` True)

-- | A spending form post with only the first (required) split line
-- filled in — lines 2/3 blank, as they'd be if a user never touched
-- them (see Api.Transactions.parseOptionalLine).
singleLineSpending :: String -> String -> String -> String -> [(String, String)]
singleLineSpending day accountId categoryId amount =
  [ ("spendingAccountId", accountId)
  , ("spendingDate", day)
  , ("spendingPayee", "Supermarket")
  , ("spendingCategoryId1", categoryId)
  , ("spendingAmount1", amount)
  , ("spendingCategoryId2", "")
  , ("spendingAmount2", "")
  , ("spendingCategoryId3", "")
  , ("spendingAmount3", "")
  ]

bodyContains :: String -> SResponse -> Bool
bodyContains needle = (needle `isInfixOf`) . BSL8.unpack . simpleBody

-- | Case-insensitive: Lucid's exact casing for the doctype declaration
-- isn't a contract worth pinning a test to.
bodyContainsCI :: String -> SResponse -> Bool
bodyContainsCI needle = (map toLower needle `isInfixOf`) . map toLower . BSL8.unpack . simpleBody
