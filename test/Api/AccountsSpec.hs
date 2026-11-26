module Api.AccountsSpec (spec) where

import Api.Setup (withTestApp)
import qualified Data.ByteString.Lazy.Char8 as BSL8
import Data.List (isInfixOf)
import Network.HTTP.Types (hLocation)
import Network.Wai.Test (SResponse (simpleBody, simpleHeaders))
import Test.Hspec
import Test.Hspec.Wai

spec :: Spec
spec = with withTestApp $ do
  describe "GET /" $
    it "redirects to /accounts" $ do
      response <- get "/"
      liftIO (response `shouldSatisfy` ((== Just "/accounts") . lookup hLocation . simpleHeaders))

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

bodyContains :: String -> SResponse -> Bool
bodyContains needle = (needle `isInfixOf`) . BSL8.unpack . simpleBody
