module Main (main) where

import Api (application)
import Api.Monad (AppEnv (AppEnv))
import Config (Config (configDbPath, configPort), loadConfig)
import Db.Pool (createPool)
import Network.Wai.Handler.Warp (run)
import System.IO (hSetEncoding, stderr, stdout, utf8)

main :: IO ()
main = do
  -- Zonder dit crasht de app op Windows zodra er een niet-ASCII teken
  -- (em-dash, "é" in een categorienaam, ...) naar de console gaat: de
  -- actieve codepage daar is zelden UTF-8, en de standaard-encoding van
  -- stdout/stderr volgt die codepage.
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8
  config <- loadConfig
  pool <- createPool (configDbPath config)
  let env = AppEnv pool
  putStrLn ("bucktracker: database gereed op " <> configDbPath config <> " (migraties toegepast).")
  putStrLn ("bucktracker: luistert op http://localhost:" <> show (configPort config))
  run (configPort config) (application env)
