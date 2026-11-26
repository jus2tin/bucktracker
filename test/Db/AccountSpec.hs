module Db.AccountSpec (spec) where

import Db.Account (archiveAccount, getAccount, insertAccount, listAccounts)
import Db.Setup (expectRight, withTestDb)
import Domain.Account (Account (accId, accName, accType), isArchived)
import Domain.Error (DomainError (EmptyName))
import Domain.Types (AccountType (Cash, Checking, Tracking))
import Test.Hspec

spec :: Spec
spec = around withTestDb $
  describe "Db.Account" $ do
    it "rejects an empty name without adding a row" $ \conn -> do
      result <- insertAccount conn "   " Checking
      result `shouldBe` Left (EmptyName "account")
      accounts <- listAccounts conn
      accounts `shouldBe` []

    it "round-trips a valid account" $ \conn -> do
      acc <- insertAccount conn "Checking Account" Checking >>= expectRight
      accName acc `shouldBe` "Checking Account"
      accType acc `shouldBe` Checking
      isArchived acc `shouldBe` False
      found <- getAccount conn (accId acc)
      found `shouldBe` Just acc

    it "listAccounts returns all accounts, sorted by id" $ \conn -> do
      a1 <- insertAccount conn "A" Checking >>= expectRight
      a2 <- insertAccount conn "B" Tracking >>= expectRight
      accounts <- listAccounts conn
      accounts `shouldBe` [a1, a2]

    it "archiveAccount sets archived_at, which persists on re-fetch" $ \conn -> do
      acc <- insertAccount conn "Old Account" Cash >>= expectRight
      archiveAccount conn (accId acc)
      maybeArchived <- getAccount conn (accId acc)
      case maybeArchived of
        Just archived -> isArchived archived `shouldBe` True
        Nothing -> expectationFailure "account disappeared after archiveAccount"
