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
    it "stuurt door naar /accounts" $ do
      response <- get "/"
      liftIO (response `shouldSatisfy` ((== Just "/accounts") . lookup hLocation . simpleHeaders))

  describe "GET /accounts" $
    it "toont een lege tabel zolang er geen rekeningen zijn" $
      get "/accounts" `shouldRespondWith` 200

  describe "POST /accounts" $ do
    it "maakt een rekening aan en toont 'm in de tabel" $ do
      response <- postHtmlForm "/accounts" [("name", "Betaalrekening"), ("accountType", "checking")]
      liftIO (bodyContains "Betaalrekening" response `shouldBe` True)

    it "wijst een lege naam af met een foutmelding, zonder een rij toe te voegen" $ do
      response <- postHtmlForm "/accounts" [("name", ""), ("accountType", "checking")]
      liftIO (bodyContains "Naam mag niet leeg zijn" response `shouldBe` True)

  describe "POST /accounts/:id/archive" $
    it "archiveert de rekening: de knop verdwijnt, de status verandert" $ do
      _ <- postHtmlForm "/accounts" [("name", "Oude rekening"), ("accountType", "cash")]
      response <- postHtmlForm "/accounts/1/archive" []
      liftIO (bodyContains "Gearchiveerd" response `shouldBe` True)
      liftIO (bodyContains "Archiveer<" response `shouldBe` False)

bodyContains :: String -> SResponse -> Bool
bodyContains needle = (needle `isInfixOf`) . BSL8.unpack . simpleBody
