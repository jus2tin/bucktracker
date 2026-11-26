module Db.MigrationsSpec (spec) where

import Database.SQLite.Simple (Only, query_)
import Db.Migrations (runMigrations)
import Db.Setup (withTestDb)
import Test.Hspec

spec :: Spec
spec = around withTestDb $
  describe "runMigrations" $ do
    it "laat precies één toegepaste migratie achter" $ \conn -> do
      rows <- query_ conn "SELECT filename FROM schema_migrations" :: IO [Only String]
      length rows `shouldBe` 1

    it "is idempotent: een tweede keer draaien verandert niets en faalt niet" $ \conn -> do
      runMigrations conn -- withTestDb draaide 'm al één keer; dit is de tweede keer
      rows <- query_ conn "SELECT filename FROM schema_migrations" :: IO [Only String]
      length rows `shouldBe` 1
