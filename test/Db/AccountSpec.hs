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
    it "wijst een lege naam af zonder een rij toe te voegen" $ \conn -> do
      result <- insertAccount conn "   " Checking
      result `shouldBe` Left (EmptyName "account")
      accounts <- listAccounts conn
      accounts `shouldBe` []

    it "rondt een geldige rekening volledig" $ \conn -> do
      acc <- insertAccount conn "Betaalrekening" Checking >>= expectRight
      accName acc `shouldBe` "Betaalrekening"
      accType acc `shouldBe` Checking
      isArchived acc `shouldBe` False
      found <- getAccount conn (accId acc)
      found `shouldBe` Just acc

    it "listAccounts geeft alle rekeningen terug, op id gesorteerd" $ \conn -> do
      a1 <- insertAccount conn "A" Checking >>= expectRight
      a2 <- insertAccount conn "B" Tracking >>= expectRight
      accounts <- listAccounts conn
      accounts `shouldBe` [a1, a2]

    it "archiveAccount zet archived_at, en dat blijft bewaard bij opnieuw opvragen" $ \conn -> do
      acc <- insertAccount conn "Oude rekening" Cash >>= expectRight
      archiveAccount conn (accId acc)
      maybeArchived <- getAccount conn (accId acc)
      case maybeArchived of
        Just archived -> isArchived archived `shouldBe` True
        Nothing -> expectationFailure "account verdween na archiveAccount"
