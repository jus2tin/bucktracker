module Db.PoolSpec (spec) where

import Control.Exception (bracket)
import Data.Text (Text)
import qualified Data.Text as Text
import Database.SQLite.Simple (Only (Only), query_)
import Db.Account (listAccounts)
import Db.Pool (closePool, createPool, withConnection)
import System.Directory
  ( doesDirectoryExist
  , doesFileExist
  , getTemporaryDirectory
  , removeDirectoryRecursive
  , removeFile
  )
import System.FilePath ((</>))
import Test.Hspec

spec :: Spec
spec =
  describe "createPool" $ do
    it "creates the parent directory of the db path if it doesn't exist yet" $ do
      tmpDir <- getTemporaryDirectory
      let nestedDir = tmpDir </> "bucktracker-pool-test-dir"
          dbPath = nestedDir </> "nested" </> "test.db"
      removeIfExists nestedDir

      bracket (createPool dbPath) closePool $ \pool -> do
        accounts <- withConnection pool listAccounts
        accounts `shouldBe` []

      removeIfExists nestedDir

    -- | Track B §1.2: every pooled connection gets the same four
    -- pragmas, and the database file itself is switched into WAL mode
    -- once at pool creation.
    it "configures busy_timeout, foreign_keys, synchronous, temp_store and WAL on every pooled connection" $ do
      tmpDir <- getTemporaryDirectory
      let dbPath = tmpDir </> "bucktracker-pool-pragma-test.db"
      removeFileIfExists dbPath
      removeFileIfExists (dbPath <> "-wal")
      removeFileIfExists (dbPath <> "-shm")

      bracket (createPool dbPath) closePool $ \pool ->
        withConnection pool $ \conn -> do
          [Only busyTimeout] <- query_ conn "PRAGMA busy_timeout" :: IO [Only Int]
          [Only foreignKeys] <- query_ conn "PRAGMA foreign_keys" :: IO [Only Int]
          [Only synchronous] <- query_ conn "PRAGMA synchronous" :: IO [Only Int]
          [Only tempStore] <- query_ conn "PRAGMA temp_store" :: IO [Only Int]
          [Only journalMode] <- query_ conn "PRAGMA journal_mode" :: IO [Only Text]
          busyTimeout `shouldBe` 5000
          foreignKeys `shouldBe` 1
          synchronous `shouldBe` 1 -- NORMAL
          tempStore `shouldBe` 2 -- MEMORY
          Text.toLower journalMode `shouldBe` "wal"

      removeFileIfExists dbPath
      removeFileIfExists (dbPath <> "-wal")
      removeFileIfExists (dbPath <> "-shm")

removeIfExists :: FilePath -> IO ()
removeIfExists dir = do
  exists <- doesDirectoryExist dir
  if exists then removeDirectoryRecursive dir else pure ()

removeFileIfExists :: FilePath -> IO ()
removeFileIfExists path = do
  exists <- doesFileExist path
  if exists then removeFile path else pure ()
