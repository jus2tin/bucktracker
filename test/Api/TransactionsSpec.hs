module Api.TransactionsSpec (spec) where

import Api.Setup (postHtmlFormHx, withTestApp)
import qualified Data.ByteString.Lazy.Char8 as BSL8
import Data.Char (toLower)
import Data.List (isInfixOf)
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Lazy.Encoding as TLE
import Data.Time (getCurrentTime, showGregorian, utctDay)
import Network.Wai.Test (SResponse (simpleBody))
import Test.Hspec
import Test.Hspec.Wai

-- | A mutation (create/edit/delete/clear) always re-renders the
-- default view — today's month, no account filter (see Api.Transactions
-- module header) — so posting a transaction dated today keeps these
-- tests passing regardless of which real month they happen to run in.
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

  describe "month navigation" $ do
    it "shows the viewed month and links to the previous/next ones" $ do
      response <- get "/transactions?month=2026-06"
      liftIO (bodyContains "2026-06" response `shouldBe` True)
      liftIO (bodyContains "/transactions?month=2026-05" response `shouldBe` True)
      liftIO (bodyContains "/transactions?month=2026-07" response `shouldBe` True)

    it "only shows transactions dated within the viewed month" $ do
      _ <- postHtmlForm "/accounts" [("name", "Checking"), ("accountType", "checking")]
      _ <-
        postHtmlForm
          "/transactions/inflow"
          [("inflowAccountId", "1"), ("inflowDate", "2026-06-15"), ("inflowPayee", "June Salary"), ("inflowAmount", "100.00")]
      _ <-
        postHtmlForm
          "/transactions/inflow"
          [("inflowAccountId", "1"), ("inflowDate", "2026-07-01"), ("inflowPayee", "July Salary"), ("inflowAmount", "200.00")]
      juneView <- get "/transactions?month=2026-06"
      liftIO (bodyContains "June Salary" juneView `shouldBe` True)
      liftIO (bodyContains "July Salary" juneView `shouldBe` False)

  describe "out-of-range ?month= and transaction dates (AUDIT-01)" $ do
    it "falls back to today's local month on an astronomically large ?month=, instead of hanging or OOMing" $ do
      day <- liftIO today
      let thisMonth = take 7 day -- "YYYY-MM-DD" -> "YYYY-MM"
      response <- get "/transactions?month=99999999-01"
      liftIO (bodyContains thisMonth response `shouldBe` True)

    it "rejects a transaction date with a year outside [1900,2200], without adding a row" $ do
      _ <- postHtmlForm "/accounts" [("name", "Checking"), ("accountType", "checking")]
      response <-
        postHtmlForm
          "/transactions/inflow"
          [("inflowAccountId", "1"), ("inflowDate", "99999999-01-01"), ("inflowPayee", "Salary"), ("inflowAmount", "100.00")]
      liftIO (bodyContains "Invalid date" response `shouldBe` True)
      liftIO (bodyContains "Salary" response `shouldBe` False)

  describe "account filtering" $
    it "?account=<id> only shows that account's transactions, and the Accounts page links to it" $ do
      _ <- postHtmlForm "/accounts" [("name", "Checking"), ("accountType", "checking")]
      _ <- postHtmlForm "/accounts" [("name", "Savings"), ("accountType", "savings")]
      day <- liftIO today
      _ <-
        postHtmlForm
          "/transactions/inflow"
          [("inflowAccountId", "1"), ("inflowDate", day), ("inflowPayee", "Checking Salary"), ("inflowAmount", "100.00")]
      _ <-
        postHtmlForm
          "/transactions/inflow"
          [("inflowAccountId", "2"), ("inflowDate", day), ("inflowPayee", "Savings Interest"), ("inflowAmount", "5.00")]
      filtered <- get "/transactions?account=1"
      liftIO (bodyContains "Checking Salary" filtered `shouldBe` True)
      liftIO (bodyContains "Savings Interest" filtered `shouldBe` False)
      liftIO (bodyContains "[show all accounts]" filtered `shouldBe` True)

      accountsPage <- get "/accounts"
      liftIO (bodyContains "/transactions?account=1" accountsPage `shouldBe` True)

  describe "Account column" $
    it "shows which account each transaction belongs to" $ do
      _ <- postHtmlForm "/accounts" [("name", "Checking"), ("accountType", "checking")]
      day <- liftIO today
      response <-
        postHtmlForm
          "/transactions/inflow"
          [("inflowAccountId", "1"), ("inflowDate", day), ("inflowPayee", "Salary"), ("inflowAmount", "100.00")]
      liftIO (bodyContains "Checking" response `shouldBe` True)

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

    it "accepts a negative amount, as an opening-balance correction (S-2.4 fix)" $ do
      _ <- postHtmlForm "/accounts" [("name", "Checking"), ("accountType", "checking")]
      day <- liftIO today
      response <-
        postHtmlForm
          "/transactions/inflow"
          [("inflowAccountId", "1"), ("inflowDate", day), ("inflowPayee", "Correction"), ("inflowAmount", "-50.00")]
      liftIO (bodyContains "-50.00" response `shouldBe` True)

    it "rejects a zero amount" $ do
      _ <- postHtmlForm "/accounts" [("name", "Checking"), ("accountType", "checking")]
      day <- liftIO today
      response <-
        postHtmlForm
          "/transactions/inflow"
          [("inflowAccountId", "1"), ("inflowDate", day), ("inflowPayee", "Salary"), ("inflowAmount", "0.00")]
      liftIO (bodyContains "Invalid amount" response `shouldBe` True)

    it "rejects a new inflow on an archived account" $ do
      _ <- postHtmlForm "/accounts" [("name", "Checking"), ("accountType", "checking")]
      _ <- postHtmlForm "/accounts/1/archive" []
      day <- liftIO today
      response <-
        postHtmlForm
          "/transactions/inflow"
          [("inflowAccountId", "1"), ("inflowDate", day), ("inflowPayee", "Salary"), ("inflowAmount", "100.00")]
      liftIO (bodyContains "archived account" response `shouldBe` True)
      liftIO (bodyContains "Salary" response `shouldBe` False)

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
          , ("lineCategoryId", "1")
          , ("lineAmount", "40.00")
          , ("lineCategoryId", "2")
          , ("lineAmount", "24.30")
          ]
      liftIO (bodyContains "Groceries, Household" response `shouldBe` True)
      liftIO (bodyContains "-64.30" response `shouldBe` True) -- 40.00 + 24.30, derived, not stored separately

    it "splits an expense across five categories" $ do
      _ <- postHtmlForm "/accounts" [("name", "Checking"), ("accountType", "checking")]
      _ <- postHtmlForm "/category-groups" [("name", "Everyday Expenses")]
      _ <- postHtmlForm "/categories" [("categoryName", "Cat1"), ("groupId", "1")]
      _ <- postHtmlForm "/categories" [("categoryName", "Cat2"), ("groupId", "1")]
      _ <- postHtmlForm "/categories" [("categoryName", "Cat3"), ("groupId", "1")]
      _ <- postHtmlForm "/categories" [("categoryName", "Cat4"), ("groupId", "1")]
      _ <- postHtmlForm "/categories" [("categoryName", "Cat5"), ("groupId", "1")]
      day <- liftIO today
      response <-
        postHtmlForm
          "/transactions/spending"
          [ ("spendingAccountId", "1")
          , ("spendingDate", day)
          , ("spendingPayee", "Supermarket")
          , ("lineCategoryId", "1")
          , ("lineAmount", "10.00")
          , ("lineCategoryId", "2")
          , ("lineAmount", "10.00")
          , ("lineCategoryId", "3")
          , ("lineAmount", "10.00")
          , ("lineCategoryId", "4")
          , ("lineAmount", "10.00")
          , ("lineCategoryId", "5")
          , ("lineAmount", "10.00")
          ]
      liftIO (bodyContains "Cat1, Cat2, Cat3, Cat4, Cat5" response `shouldBe` True)
      liftIO (bodyContains "-50.00" response `shouldBe` True)

    it "accepts a negative line amount as a refund/credit against that category (S-2.3 fix)" $ do
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
          , ("spendingPayee", "Supermarket refund")
          , ("lineCategoryId", "1")
          , ("lineAmount", "40.00")
          , ("lineCategoryId", "2")
          , ("lineAmount", "-15.00")
          ]
      -- net total: -40.00 + 15.00 = -25.00
      liftIO (bodyContains "-25.00" response `shouldBe` True)

    it "rejects a zero-amount split line" $ do
      _ <- postHtmlForm "/accounts" [("name", "Checking"), ("accountType", "checking")]
      _ <- postHtmlForm "/category-groups" [("name", "Everyday Expenses")]
      _ <- postHtmlForm "/categories" [("categoryName", "Groceries"), ("groupId", "1")]
      day <- liftIO today
      response <- postHtmlForm "/transactions/spending" (singleLineSpending day "1" "1" "0.00")
      liftIO (bodyContains "Invalid amount" response `shouldBe` True)

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

    it "rejects a new expense on an archived account" $ do
      _ <- postHtmlForm "/accounts" [("name", "Checking"), ("accountType", "checking")]
      _ <- postHtmlForm "/accounts/1/archive" []
      _ <- postHtmlForm "/category-groups" [("name", "Everyday Expenses")]
      _ <- postHtmlForm "/categories" [("categoryName", "Groceries"), ("groupId", "1")]
      day <- liftIO today
      response <- postHtmlForm "/transactions/spending" (singleLineSpending day "1" "1" "12.34")
      liftIO (bodyContains "archived account" response `shouldBe` True)

    it "rejects a split line against an archived category" $ do
      _ <- postHtmlForm "/accounts" [("name", "Checking"), ("accountType", "checking")]
      _ <- postHtmlForm "/category-groups" [("name", "Everyday Expenses")]
      _ <- postHtmlForm "/categories" [("categoryName", "Groceries"), ("groupId", "1")]
      _ <- postHtmlForm "/categories/1/archive" []
      day <- liftIO today
      response <- postHtmlForm "/transactions/spending" (singleLineSpending day "1" "1" "12.34")
      liftIO (bodyContains "archived category" response `shouldBe` True)

    it "the spending account picker excludes tracking accounts, unlike the inflow/transfer pickers" $ do
      _ <- postHtmlForm "/accounts" [("name", "Checking"), ("accountType", "checking")]
      _ <- postHtmlForm "/accounts" [("name", "Investments"), ("accountType", "tracking")]
      response <- get "/transactions"
      -- "Investments" is offered by the inflow picker and both transfer
      -- pickers (3 selects) but deliberately not the spending one — a
      -- 'Domain.Transaction.Categorized' transaction can never legally
      -- land on a tracking account.
      liftIO (countOccurrences "Investments" response `shouldBe` 3)

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

    it "rejects a new transfer touching an archived account" $ do
      _ <- postHtmlForm "/accounts" [("name", "Checking"), ("accountType", "checking")]
      _ <- postHtmlForm "/accounts" [("name", "Savings"), ("accountType", "savings")]
      _ <- postHtmlForm "/accounts/2/archive" []
      day <- liftIO today
      response <-
        postHtmlForm
          "/transactions/transfer"
          [("transferFromAccountId", "1"), ("transferToAccountId", "2"), ("transferDate", day), ("transferAmount", "50.00")]
      liftIO (bodyContains "archived account" response `shouldBe` True)

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

  describe "POST /transactions/:id/delete" $ do
    it "removes the transaction from the register" $ do
      _ <- postHtmlForm "/accounts" [("name", "Checking"), ("accountType", "checking")]
      day <- liftIO today
      _ <-
        postHtmlForm
          "/transactions/inflow"
          [("inflowAccountId", "1"), ("inflowDate", day), ("inflowPayee", "Salary"), ("inflowAmount", "100.00")]
      response <- postHtmlForm "/transactions/1/delete" []
      liftIO (bodyContains "Salary" response `shouldBe` False)

    it "is blocked on an already-Reconciled transaction, with an error message" $ do
      _ <- postHtmlForm "/accounts" [("name", "Checking"), ("accountType", "checking")]
      day <- liftIO today
      _ <-
        postHtmlForm
          "/transactions/inflow"
          [("inflowAccountId", "1"), ("inflowDate", day), ("inflowPayee", "Salary"), ("inflowAmount", "100.00")]
      _ <- postHtmlForm "/transactions/1/clear" []
      _ <- postHtmlForm "/accounts/1/reconcile" [("statementBalance", "100.00")]
      response <- postHtmlForm "/transactions/1/delete" []
      liftIO (bodyContains "Cannot delete a reconciled transaction" response `shouldBe` True)
      liftIO (bodyContains "Salary" response `shouldBe` True)

  describe "POST /transactions/:id/edit-inflow" $
    it "updates the payee and amount shown in the register" $ do
      _ <- postHtmlForm "/accounts" [("name", "Checking"), ("accountType", "checking")]
      day <- liftIO today
      _ <-
        postHtmlForm
          "/transactions/inflow"
          [("inflowAccountId", "1"), ("inflowDate", day), ("inflowPayee", "Salary"), ("inflowAmount", "100.00")]
      response <-
        postHtmlForm
          "/transactions/1/edit-inflow"
          [("inflowAccountId", "1"), ("inflowDate", day), ("inflowPayee", "Corrected Salary"), ("inflowAmount", "150.00")]
      liftIO (bodyContains "Corrected Salary" response `shouldBe` True)
      liftIO (bodyContains "150.00" response `shouldBe` True)
      liftIO (bodyContains "100.00" response `shouldBe` False)

  describe "POST /transactions/:id/edit-spending" $
    it "updates the split lines shown in the register" $ do
      _ <- postHtmlForm "/accounts" [("name", "Checking"), ("accountType", "checking")]
      _ <- postHtmlForm "/category-groups" [("name", "Everyday Expenses")]
      _ <- postHtmlForm "/categories" [("categoryName", "Groceries"), ("groupId", "1")]
      _ <- postHtmlForm "/categories" [("categoryName", "Household"), ("groupId", "1")]
      day <- liftIO today
      _ <- postHtmlForm "/transactions/spending" (singleLineSpending day "1" "1" "40.00")
      response <-
        postHtmlForm
          "/transactions/1/edit-spending"
          [ ("spendingAccountId", "1")
          , ("spendingDate", day)
          , ("spendingPayee", "Corrected")
          , ("lineCategoryId", "2")
          , ("lineAmount", "25.00")
          ]
      liftIO (bodyContains "Household" response `shouldBe` True)
      liftIO (bodyContains "-25.00" response `shouldBe` True)
      liftIO (bodyContains "-40.00" response `shouldBe` False)

  describe "POST /transactions/:id/edit-transfer" $
    it "updates the accounts and amount of both legs" $ do
      _ <- postHtmlForm "/accounts" [("name", "Checking"), ("accountType", "checking")]
      _ <- postHtmlForm "/accounts" [("name", "Savings"), ("accountType", "savings")]
      _ <- postHtmlForm "/accounts" [("name", "Cash"), ("accountType", "cash")]
      day <- liftIO today
      _ <-
        postHtmlForm
          "/transactions/transfer"
          [("transferFromAccountId", "1"), ("transferToAccountId", "2"), ("transferDate", day), ("transferAmount", "50.00")]
      response <-
        postHtmlForm
          "/transactions/1/edit-transfer"
          [("transferFromAccountId", "1"), ("transferToAccountId", "3"), ("transferDate", day), ("transferAmount", "75.00")]
      liftIO (bodyContains "Transfer: Cash" response `shouldBe` True)
      liftIO (bodyContains "75.00" response `shouldBe` True)

  describe "editing onto a *different*, newly chosen archived account/category is rejected (AUDIT-03.3)" $ do
    it "rejects edit-inflow moving the transaction onto a different archived account" $ do
      _ <- postHtmlForm "/accounts" [("name", "Checking"), ("accountType", "checking")]
      _ <- postHtmlForm "/accounts" [("name", "Old Savings"), ("accountType", "savings")]
      _ <- postHtmlForm "/accounts/2/archive" []
      day <- liftIO today
      _ <-
        postHtmlForm
          "/transactions/inflow"
          [("inflowAccountId", "1"), ("inflowDate", day), ("inflowPayee", "Salary"), ("inflowAmount", "100.00")]
      response <-
        postHtmlForm
          "/transactions/1/edit-inflow"
          [("inflowAccountId", "2"), ("inflowDate", day), ("inflowPayee", "Salary"), ("inflowAmount", "100.00")]
      liftIO (bodyContains "archived account" response `shouldBe` True)
      liftIO (bodyContains "Old Savings" response `shouldBe` False)

    it "rejects edit-spending moving a line onto a different archived category" $ do
      _ <- postHtmlForm "/accounts" [("name", "Checking"), ("accountType", "checking")]
      _ <- postHtmlForm "/category-groups" [("name", "Everyday Expenses")]
      _ <- postHtmlForm "/categories" [("categoryName", "Groceries"), ("groupId", "1")]
      _ <- postHtmlForm "/categories" [("categoryName", "Old Category"), ("groupId", "1")]
      _ <- postHtmlForm "/categories/2/archive" []
      day <- liftIO today
      _ <- postHtmlForm "/transactions/spending" (singleLineSpending day "1" "1" "40.00")
      response <-
        postHtmlForm
          "/transactions/1/edit-spending"
          [ ("spendingAccountId", "1")
          , ("spendingDate", day)
          , ("spendingPayee", "Corrected")
          , ("lineCategoryId", "2")
          , ("lineAmount", "40.00")
          ]
      liftIO (bodyContains "archived category" response `shouldBe` True)
      liftIO (bodyContains "-40.00" response `shouldBe` True) -- the original is untouched

    it "rejects edit-transfer moving a leg onto a different archived account" $ do
      _ <- postHtmlForm "/accounts" [("name", "Checking"), ("accountType", "checking")]
      _ <- postHtmlForm "/accounts" [("name", "Savings"), ("accountType", "savings")]
      _ <- postHtmlForm "/accounts" [("name", "Old Cash"), ("accountType", "cash")]
      _ <- postHtmlForm "/accounts/3/archive" []
      day <- liftIO today
      _ <-
        postHtmlForm
          "/transactions/transfer"
          [("transferFromAccountId", "1"), ("transferToAccountId", "2"), ("transferDate", day), ("transferAmount", "50.00")]
      response <-
        postHtmlForm
          "/transactions/1/edit-transfer"
          [("transferFromAccountId", "1"), ("transferToAccountId", "3"), ("transferDate", day), ("transferAmount", "50.00")]
      liftIO (bodyContains "archived account" response `shouldBe` True)
      liftIO (bodyContains "Old Cash" response `shouldBe` False)

  describe "cross-kind edits are rejected (AUDIT-03.2)" $
    it "rejects edit-inflow for an id that's actually a split transaction, leaving it untouched" $ do
      _ <- postHtmlForm "/accounts" [("name", "Checking"), ("accountType", "checking")]
      _ <- postHtmlForm "/category-groups" [("name", "Everyday Expenses")]
      _ <- postHtmlForm "/categories" [("categoryName", "Groceries"), ("groupId", "1")]
      day <- liftIO today
      _ <- postHtmlForm "/transactions/spending" (singleLineSpending day "1" "1" "40.00")
      response <-
        postHtmlForm
          "/transactions/1/edit-inflow"
          [("inflowAccountId", "1"), ("inflowDate", day), ("inflowPayee", "Hijacked"), ("inflowAmount", "100.00")]
      liftIO (bodyContains "kind of transaction" response `shouldBe` True)
      liftIO (bodyContains "-40.00" response `shouldBe` True)
      liftIO (bodyContains "Hijacked" response `shouldBe` False)

  describe "mismatched split line fields are rejected (AUDIT-03.4)" $
    it "rejects a spending POST with more lineCategoryId fields than lineAmount fields" $ do
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
          , ("lineCategoryId", "1")
          , ("lineCategoryId", "2")
          , ("lineAmount", "40.00")
          ]
      liftIO (bodyContains "Mismatched category/amount fields" response `shouldBe` True)
      liftIO (bodyContains "Supermarket" response `shouldBe` False)

  describe "transfer reconciliation lock applies to both legs (AUDIT-02)" $
    it "blocks editing/deleting the not-yet-reconciled leg once its sibling leg is Reconciled, and hides its Edit control" $ do
      _ <- postHtmlForm "/accounts" [("name", "Checking"), ("accountType", "checking")]
      _ <- postHtmlForm "/accounts" [("name", "Savings"), ("accountType", "savings")]
      day <- liftIO today
      _ <-
        postHtmlForm
          "/transactions/transfer"
          [("transferFromAccountId", "1"), ("transferToAccountId", "2"), ("transferDate", day), ("transferAmount", "50.00")]
      _ <- postHtmlForm "/transactions/1/clear" []
      _ <- postHtmlForm "/accounts/1/reconcile" [("statementBalance", "-50.00")]

      page <- get "/transactions"
      liftIO (bodyContains "edit-details-2" page `shouldBe` False)

      deleteResponse <- postHtmlForm "/transactions/2/delete" []
      liftIO (bodyContains "Cannot delete a reconciled transaction" deleteResponse `shouldBe` True)
      liftIO (bodyContains "Transfer: Checking" deleteResponse `shouldBe` True)

      editResponse <-
        postHtmlForm
          "/transactions/2/edit-transfer"
          [("transferFromAccountId", "1"), ("transferToAccountId", "2"), ("transferDate", day), ("transferAmount", "75.00")]
      liftIO (bodyContains "Cannot edit a reconciled transaction" editResponse `shouldBe` True)

  describe "payee validation (AUDIT-08)" $
    it "rejects a payee containing a control character, without adding a row" $ do
      _ <- postHtmlForm "/accounts" [("name", "Checking"), ("accountType", "checking")]
      day <- liftIO today
      response <-
        postHtmlForm
          "/transactions/inflow"
          [("inflowAccountId", "1"), ("inflowDate", day), ("inflowPayee", "Salary\tBonus"), ("inflowAmount", "100.00")]
      liftIO (bodyContains "Invalid payee" response `shouldBe` True)

-- | A spending form post with a single split line.
singleLineSpending :: String -> String -> String -> String -> [(String, String)]
singleLineSpending day accountId categoryId amount =
  [ ("spendingAccountId", accountId)
  , ("spendingDate", day)
  , ("spendingPayee", "Supermarket")
  , ("lineCategoryId", categoryId)
  , ("lineAmount", amount)
  ]

bodyContains :: String -> SResponse -> Bool
bodyContains needle = (needle `isInfixOf`) . BSL8.unpack . simpleBody

-- | Case-insensitive: Lucid's exact casing for the doctype declaration
-- isn't a contract worth pinning a test to.
bodyContainsCI :: String -> SResponse -> Bool
bodyContainsCI needle = (map toLower needle `isInfixOf`) . map toLower . BSL8.unpack . simpleBody

countOccurrences :: TL.Text -> SResponse -> Int
countOccurrences needle = fromIntegral . TL.count needle . TLE.decodeUtf8 . simpleBody
