module Api.StaticSpec (spec) where

import qualified Data.ByteString.Char8 as BS8
import Data.List (isInfixOf)
import Network.HTTP.Types (hContentType, status200)
import Network.Wai.Test (SResponse (simpleHeaders, simpleStatus))
import Api.Setup (withTestApp)
import Test.Hspec
import Test.Hspec.Wai

spec :: Spec
spec = with withTestApp $ do
  describe "GET /static/pico.min.css" $
    it "serves the vendored stylesheet with a CSS content type" $ do
      response <- get "/static/pico.min.css"
      liftIO (simpleStatus response `shouldBe` status200)
      liftIO (contentTypeContains "css" response `shouldBe` True)

  describe "GET /static/htmx.min.js" $
    it "serves the vendored HTMX library with a JS content type" $ do
      response <- get "/static/htmx.min.js"
      liftIO (simpleStatus response `shouldBe` status200)
      liftIO (contentTypeContains "javascript" response `shouldBe` True)

  describe "GET /static/alpine-csp.min.js" $
    it "serves the vendored Alpine.js CSP build with a JS content type" $ do
      response <- get "/static/alpine-csp.min.js"
      liftIO (simpleStatus response `shouldBe` status200)
      liftIO (contentTypeContains "javascript" response `shouldBe` True)

  describe "GET /static/app.js" $
    it "serves our own static JS file" $
      get "/static/app.js" `shouldRespondWith` 200

  describe "GET /static/does-not-exist.js" $
    it "404s on an unknown static asset, rather than falling back to a page" $
      get "/static/does-not-exist.js" `shouldRespondWith` 404

contentTypeContains :: String -> SResponse -> Bool
contentTypeContains needle response =
  case lookup hContentType (simpleHeaders response) of
    Just ct -> needle `isInfixOf` BS8.unpack ct
    Nothing -> False
