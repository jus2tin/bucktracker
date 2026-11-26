module Main (main) where

import Config (Config (configDbPath, configPort), loadConfig)
import Db.Pool (createPool)
import System.IO (hSetEncoding, stderr, stdout, utf8)

-- | Laadt config en zet de SQLite-pool + migraties op (Fase 2). De
-- Warp-server (Fase 3, Api/) volgt nog niet — zie DECISIONS.md.
main :: IO ()
main = do
  -- Zonder dit crasht de app op Windows zodra er een niet-ASCII teken
  -- (em-dash, "é" in een categorienaam, ...) naar de console gaat: de
  -- actieve codepage daar is zelden UTF-8, en de standaard-encoding van
  -- stdout/stderr volgt die codepage.
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8
  config <- loadConfig
  _pool <- createPool (configDbPath config)
  putStrLn ("bucktracker: database gereed op " <> configDbPath config <> " (migraties toegepast).")
  putStrLn
    ( "Api/-laag volgt in Fase 3 — zou anders geluisterd hebben op poort "
        <> show (configPort config)
        <> "."
    )
