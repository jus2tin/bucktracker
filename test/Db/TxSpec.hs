module Db.TxSpec (spec) where

import Control.Exception (Exception, throwIO, try)
import Data.Text (Text)
import Database.SQLite.Simple (Connection, Only (Only), execute, query_)
import Db.Setup (withTestDb)
import Db.Tx (withImmediateTransaction, withReadSnapshot)
import Test.Hspec

newtype Boom = Boom String deriving stock (Show)
instance Exception Boom

spec :: Spec
spec = around withTestDb $
  describe "Db.Tx" $ do
    describe "withImmediateTransaction" $ do
      it "commits every write once the action completes normally" $ \conn -> do
        withImmediateTransaction conn (insertAccount conn "Checking")
        names <- accountNames conn
        names `shouldBe` ["Checking"]

      it "rolls back every write so far if the action throws, and re-throws" $ \conn -> do
        result <-
          try (withImmediateTransaction conn (insertAccount conn "Checking" >> throwIO (Boom "nope")))
            :: IO (Either Boom ())
        case result of
          Left (Boom _) -> pure ()
          Right () -> expectationFailure "expected the action to throw"
        names <- accountNames conn
        names `shouldBe` []

      it "leaves the connection usable for a later transaction after a rollback" $ \conn -> do
        _ <-
          try (withImmediateTransaction conn (insertAccount conn "Checking" >> throwIO (Boom "nope")))
            :: IO (Either Boom ())
        withImmediateTransaction conn (insertAccount conn "Savings")
        names <- accountNames conn
        names `shouldBe` ["Savings"]

    describe "withReadSnapshot" $
      it "returns whatever the read action produces, without writing anything itself" $ \conn -> do
        insertAccount conn "Checking"
        names <- withReadSnapshot conn (accountNames conn)
        names `shouldBe` ["Checking"]

insertAccount :: Connection -> Text -> IO ()
insertAccount conn accName =
  execute conn "INSERT INTO accounts (name, type, archived_at) VALUES (?, 'checking', NULL)" (Only accName)

accountNames :: Connection -> IO [Text]
accountNames conn = map (\(Only n) -> n) <$> query_ conn "SELECT name FROM accounts ORDER BY id"
