module Main (main) where

import Api (application)
import Api.Monad (AppEnv (AppEnv))
import Config (Config (configDbPath, configPort), loadConfig)
import Control.Exception (bracket)
import Db.Pool (closePool, createPool)
import Network.Wai.Handler.Warp (defaultSettings, runSettings, setHost, setPort)
import Paths_bucktracker (getDataDir)
import System.FilePath ((</>))
import System.IO (hSetEncoding, stderr, stdout, utf8)

main :: IO ()
main = do
  -- Without this, the app crashes on Windows as soon as a non-ASCII
  -- character (em-dash, "é" in a category name, ...) goes to the
  -- console: the active codepage there is rarely UTF-8, and the default
  -- encoding of stdout/stderr follows that codepage.
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8
  config <- loadConfig
  staticDir <- (</> "static") <$> getDataDir
  -- 'bracket' (not a bare 'createPool'/let-it-leak): on a graceful
  -- shutdown (Ctrl-C/SIGTERM) or a Warp startup failure (e.g. the port
  -- is already in use), 'closePool' still runs and checkpoints the WAL
  -- back into the main database file (Track B §1.2) instead of leaving
  -- a @.db-wal@ for the next start to deal with.
  bracket (createPool (configDbPath config)) closePool $ \pool -> do
    let env = AppEnv pool staticDir
    putStrLn ("bucktracker: database ready at " <> configDbPath config <> " (migrations applied).")
    putStrLn ("bucktracker: listening on http://localhost:" <> show (configPort config))
    -- Warp's plain 'run' binds to every network interface (defaultSettings'
    -- host is "*4" = 0.0.0.0), not just loopback. That silently contradicts
    -- the no-auth assumption in CLAUDE.md/DECISIONS.md ("runs on localhost
    -- only") — anyone on the same LAN/Wi-Fi could otherwise reach this.
    -- Bind explicitly to loopback instead. Not exposed as an env var on
    -- purpose: an app with no auth should not make it easy to accidentally
    -- widen this.
    runSettings (setHost "127.0.0.1" (setPort (configPort config) defaultSettings)) (application env)
