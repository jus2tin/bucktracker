module Main (main) where

import Api (application)
import Api.Monad (AppEnv (AppEnv))
import Config (Config (configDbPath, configPort), loadConfig)
import Db.Pool (createPool)
import Network.Wai.Handler.Warp (run)
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
  pool <- createPool (configDbPath config)
  let env = AppEnv pool
  putStrLn ("bucktracker: database ready at " <> configDbPath config <> " (migrations applied).")
  putStrLn ("bucktracker: listening on http://localhost:" <> show (configPort config))
  run (configPort config) (application env)
