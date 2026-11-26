-- | Shared page layout and small HTMX helpers.
--
-- Server-rendered HTML, no npm/JS build step (DECISIONS.md §2): HTMX
-- comes from a plain CDN @\<script\>@ tag. That requires internet access
-- in the browser to load the page — a known, deliberate v0.1 limitation;
-- vendoring it as a local file (via @data-files@, like the migrations)
-- can happen later if fully-offline use turns out to be needed.
module Api.Html
  ( page
  , errorBanner
  , hxPost_
  , hxTarget_
  , hxSwap_
  ) where

import Data.Text (Text)
import Lucid
import Lucid.Base (Attribute, makeAttribute)

page :: Text -> Html () -> Html ()
page title content = doctypehtml_ $ do
  head_ $ do
    meta_ [charset_ "utf-8"]
    meta_ [name_ "viewport", content_ "width=device-width, initial-scale=1"]
    title_ (toHtml title)
    script_ [src_ "https://unpkg.com/htmx.org@2.0.3"] ("" :: Text)
    style_ pageStyle
  body_ $ do
    nav_ $ do
      a_ [href_ "/accounts"] "Accounts"
      " · "
      a_ [href_ "/categories"] "Categories"
    content

errorBanner :: Maybe Text -> Html ()
errorBanner Nothing = mempty
errorBanner (Just msg) = div_ [class_ "error"] (toHtml msg)

hxPost_ :: Text -> Attribute
hxPost_ = makeAttribute "hx-post"

hxTarget_ :: Text -> Attribute
hxTarget_ = makeAttribute "hx-target"

hxSwap_ :: Text -> Attribute
hxSwap_ = makeAttribute "hx-swap"

pageStyle :: Text
pageStyle =
  "body { font-family: system-ui, sans-serif; margin: 2rem auto; max-width: 48rem; } \
  \nav { margin-bottom: 1.5rem; } \
  \.error { color: #a00; margin-bottom: 1rem; } \
  \table { border-collapse: collapse; width: 100%; margin-top: 1rem; } \
  \td, th { padding: 0.35rem 0.6rem; border: 1px solid #ccc; text-align: left; } \
  \form { display: flex; gap: 0.5rem; align-items: center; }"
