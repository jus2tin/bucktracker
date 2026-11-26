module Db.MigrationsSpec (spec) where

import Database.SQLite.Simple (Only, query_)
import Db.Migrations (runMigrations)
import Db.Setup (withTestDb)
import Test.Hspec

spec :: Spec
spec = around withTestDb $
  describe "runMigrations" $ do
    it "leaves exactly one applied migration behind" $ \conn -> do
      rows <- query_ conn "SELECT filename FROM schema_migrations" :: IO [Only String]
      length rows `shouldBe` 1

    it "is idempotent: running it a second time changes nothing and doesn't fail" $ \conn -> do
      runMigrations conn -- withTestDb already ran it once; this is the second time
      rows <- query_ conn "SELECT filename FROM schema_migrations" :: IO [Only String]
      length rows `shouldBe` 1
