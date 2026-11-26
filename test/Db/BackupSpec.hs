module Db.BackupSpec (spec) where

import Control.Exception (bracket)
import Database.SQLite.Simple (close, open)
import Db.Account (getAccount, insertAccount)
import Db.Backup (backupTo)
import Db.Setup (expectRight, withTestDb)
import Domain.Account (Account (accId, accName))
import Domain.Types (AccountType (Checking))
import System.Directory (getTemporaryDirectory, removeFile)
import System.IO (hClose, openTempFile)
import Test.Hspec

spec :: Spec
spec = around withTestDb $
  describe "Db.Backup" $
    it "copies the current database to another file (online backup API)" $ \conn -> do
      acc <- insertAccount conn "Checking Account" Checking >>= expectRight
      withTempFile $ \destPath -> do
        backupTo conn destPath
        bracket (open destPath) close $ \destConn -> do
          found <- getAccount destConn (accId acc)
          fmap accName found `shouldBe` Just (accName acc)

-- | An empty, guaranteed-unique file path, cleaned up after use.
withTempFile :: (FilePath -> IO a) -> IO a
withTempFile action = do
  tmpDir <- getTemporaryDirectory
  bracket (openTempFile tmpDir "bucktracker-backup-test.db") (removeFile . fst) $ \(path, handle) -> do
    hClose handle
    action path
