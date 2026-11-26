module Db.PoolSpec (spec) where

import Control.Exception (bracket)
import Db.Account (listAccounts)
import Db.Pool (closePool, createPool, withConnection)
import System.Directory (doesDirectoryExist, getTemporaryDirectory, removeDirectoryRecursive)
import System.FilePath ((</>))
import Test.Hspec

spec :: Spec
spec =
  describe "createPool" $
    it "creates the parent directory of the db path if it doesn't exist yet" $ do
      tmpDir <- getTemporaryDirectory
      let nestedDir = tmpDir </> "bucktracker-pool-test-dir"
          dbPath = nestedDir </> "nested" </> "test.db"
      removeIfExists nestedDir

      bracket (createPool dbPath) closePool $ \pool -> do
        accounts <- withConnection pool listAccounts
        accounts `shouldBe` []

      removeIfExists nestedDir

removeIfExists :: FilePath -> IO ()
removeIfExists dir = do
  exists <- doesDirectoryExist dir
  if exists then removeDirectoryRecursive dir else pure ()
