module Db.MigrationsSpec (spec) where

import Control.Exception (try)
import qualified Data.ByteString as BS
import qualified Data.Text as Text
import Data.Text.Encoding (encodeUtf8)
import Database.SQLite.Simple (Connection, Only, execute_, open, query_)
import Db.Migrations (InvalidMigrationEncoding, applyMigration, runMigrations)
import Db.Setup (withTestDb)
import System.Directory (getTemporaryDirectory)
import System.FilePath (takeFileName)
import System.IO (hClose, openBinaryTempFile)
import Test.Hspec

spec :: Spec
spec = do
  around withTestDb $
    describe "runMigrations" $ do
      it "leaves exactly one applied migration behind" $ \conn -> do
        rows <- query_ conn "SELECT filename FROM schema_migrations" :: IO [Only String]
        length rows `shouldBe` 1

      it "is idempotent: running it a second time changes nothing and doesn't fail" $ \conn -> do
        runMigrations conn -- withTestDb already ran it once; this is the second time
        rows <- query_ conn "SELECT filename FROM schema_migrations" :: IO [Only String]
        length rows `shouldBe` 1

  describe "applyMigration (H-4 regression: explicit UTF-8, not the system locale)" $ do
    it "applies a file containing multi-byte UTF-8 content (e.g. an accented character) without failing" $ do
      conn <- openWithMigrationsTable
      (dir, fileName) <- tempMigrationFile (encodeUtf8 (Text.pack "-- caf\233, \167\n"))
      applyMigration conn dir fileName `shouldReturn` ()

    it "rejects a file that isn't valid UTF-8 with InvalidMigrationEncoding, instead of silently mis-decoding it" $ do
      conn <- openWithMigrationsTable
      (dir, fileName) <- tempMigrationFile (BS.pack [0xFF, 0xFE, 0x00])
      result <- try (applyMigration conn dir fileName) :: IO (Either InvalidMigrationEncoding ())
      result `shouldSatisfy` isLeftEncodingError

-- | A bare connection with just the @schema_migrations@ table that
-- 'applyMigration' writes to — everything 'runMigrations' itself would
-- normally create first, without going through the real migrations
-- (these tests are only about the file-reading step, not the schema).
openWithMigrationsTable :: IO Connection
openWithMigrationsTable = do
  conn <- open ":memory:"
  execute_
    conn
    "CREATE TABLE schema_migrations (filename TEXT PRIMARY KEY, applied_at TEXT NOT NULL)"
  pure conn

isLeftEncodingError :: Either InvalidMigrationEncoding () -> Bool
isLeftEncodingError (Left _) = True
isLeftEncodingError (Right _) = False

tempMigrationFile :: BS.ByteString -> IO (FilePath, FilePath)
tempMigrationFile contents = do
  tmpDir <- getTemporaryDirectory
  (path, handle) <- openBinaryTempFile tmpDir "bucktracker-migration-test.sql"
  BS.hPut handle contents
  hClose handle
  pure (tmpDir, takeFileName path)
