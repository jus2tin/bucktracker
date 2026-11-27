-- | Shared page layout and small HTMX/Alpine attribute helpers.
--
-- Server-rendered semantic HTML: Pico CSS for styling, HTMX for
-- interactivity, Alpine.js for ephemeral local UI state — all vendored,
-- pinned, zero build step, served from @\/static\/*@ (DECISIONS.md §12,
-- ARCHITECTURE.md "Static assets"). No npm/JS build step anywhere.
module Api.Html
  ( page
  , pageOrFragment
  , errorBanner
  , successBanner
  , hxPost_
  , hxGet_
  , hxTarget_
  , hxSwap_
  , hxConfirm_
  , hxTrigger_
  , xData_
  , xShow_
  , xText_
  , xOn_
  ) where

import Data.Text (Text)
import Lucid
import Lucid.Base (makeAttribute)

page :: Text -> Html () -> Html ()
page title content = doctypehtml_ $ do
  head_ $ do
    meta_ [charset_ "utf-8"]
    meta_ [name_ "viewport", content_ "width=device-width, initial-scale=1"]
    title_ (toHtml title)
    link_ [rel_ "stylesheet", href_ "/static/pico.min.css"]
    script_ [defer_ "", src_ "/static/htmx.min.js"] ("" :: Text)
    script_ [defer_ "", src_ "/static/alpine-csp.min.js"] ("" :: Text)
    script_ [defer_ "", src_ "/static/app.js"] ("" :: Text)
    style_ pageStyle
  body_ $ do
    header_ [class_ "container"] $
      nav_ $ do
        ul_ (li_ (strong_ "Bucktracker"))
        ul_ $ do
          li_ (a_ [href_ "/budget"] "Budget")
          li_ (a_ [href_ "/accounts"] "Accounts")
          li_ (a_ [href_ "/categories"] "Categories")
          li_ (a_ [href_ "/transactions"] "Transactions")
    main_ [class_ "container"] content

-- | Wraps @content@ in 'page' unless this came from an HTMX request
-- (the @HX-Request: true@ header; Servant hands this back as
-- 'Nothing' when the header is absent). A plain browser POST — HTMX
-- failed to load, is blocked, or JS is off — still gets a real,
-- styled page back instead of a bare, unstyled fragment; a genuine
-- HTMX request gets just the fragment it's about to swap in. This is
-- the one place that decides fragment vs. full page, so handlers never
-- have to duplicate that branch (and can't accidentally always return
-- a full page into an @hx-swap="outerHTML"@ target, which is what
-- happened before — see ARCHITECTURE.md "Request lifecycle").
pageOrFragment :: Maybe Text -> Text -> Html () -> Html ()
pageOrFragment (Just "true") _     content = content
pageOrFragment _             title content = page title content

errorBanner :: Maybe Text -> Html ()
errorBanner Nothing = mempty
errorBanner (Just msg) = p_ [class_ "error"] (toHtml msg)

-- | Positive confirmation (e.g. "account reconciled") — same shape as
-- 'errorBanner', styled differently so the two are never confused at a
-- glance.
successBanner :: Maybe Text -> Html ()
successBanner Nothing = mempty
successBanner (Just msg) = p_ [class_ "success"] (toHtml msg)

hxPost_ :: Text -> Attribute
hxPost_ = makeAttribute "hx-post"

hxGet_ :: Text -> Attribute
hxGet_ = makeAttribute "hx-get"

hxTarget_ :: Text -> Attribute
hxTarget_ = makeAttribute "hx-target"

hxSwap_ :: Text -> Attribute
hxSwap_ = makeAttribute "hx-swap"

hxConfirm_ :: Text -> Attribute
hxConfirm_ = makeAttribute "hx-confirm"

hxTrigger_ :: Text -> Attribute
hxTrigger_ = makeAttribute "hx-trigger"

-- | Alpine.js attribute helpers. Strictly for ephemeral local UI state
-- — never persistent data, never floating-point currency math
-- (DECISIONS.md §12). Not used anywhere yet; added now so every later
-- Phase 2 Track A step (dynamic split lines, live reconciliation math,
-- inline editing) reaches for the same names instead of each
-- reinventing its own 'makeAttribute' calls.
xData_ :: Text -> Attribute
xData_ = makeAttribute "x-data"

xShow_ :: Text -> Attribute
xShow_ = makeAttribute "x-show"

xText_ :: Text -> Attribute
xText_ = makeAttribute "x-text"

-- | @x-on:\<event\>="..."@, e.g. @xOn_ "click" "open = true"@.
xOn_ :: Text -> Text -> Attribute
xOn_ event = makeAttribute ("x-on:" <> event)

-- | Only what Pico CSS doesn't already style for us.
pageStyle :: Text
pageStyle =
  ".error { color: #a00; } \
  \.success { color: #070; } \
  \.amount { text-align: right; }"
