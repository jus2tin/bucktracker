-- | Connection pool rond SQLite (zie DECISIONS.md §7).
--
-- Elke andere @Db.*@-module werkt met een losse 'Connection', nooit met de
-- 'Pool' zelf — dat houdt repository-functies en tests pool-onafhankelijk
-- (een test opent gewoon zelf één @:memory:@-'Connection' en roept
-- 'Db.Migrations.runMigrations' + de repository-functies direct aan, geen
-- pool nodig). De pool is puur infrastructuur voor de (latere) Api-laag:
-- elke request leent één 'Connection', gebruikt 'm, en geeft 'm terug.
module Db.Pool
  ( Pool
  , createPool
  , withConnection
  ) where

import Data.Pool (Pool, defaultPoolConfig, newPool, withResource)
import Database.SQLite.Simple (Connection, close, execute_, open)
import Db.Migrations (runMigrations)

-- | Maakt de pool voor het gegeven SQLite-bestand, zet op elke nieuw
-- geopende connectie de afgesproken pragmas (WAL, foreign_keys,
-- busy_timeout) en draait eenmalig de migraties voordat de pool wordt
-- teruggegeven. Maximaal 8 connecties, 60 seconden idle-timeout — ruim
-- genoeg voor een single-user desktop-app, klein genoeg om geen
-- "database is locked"-stormen te riskeren.
createPool :: FilePath -> IO (Pool Connection)
createPool dbPath = do
  pool <- newPool (defaultPoolConfig (openConfigured dbPath) close 60 8)
  withResource pool runMigrations
  pure pool

openConfigured :: FilePath -> IO Connection
openConfigured dbPath = do
  conn <- open dbPath
  execute_ conn "PRAGMA journal_mode = WAL"
  execute_ conn "PRAGMA foreign_keys = ON"
  execute_ conn "PRAGMA busy_timeout = 5000"
  pure conn

withConnection :: Pool Connection -> (Connection -> IO a) -> IO a
withConnection = withResource
