-- | Backup via SQLite's online backup API (zie DECISIONS.md §7): kopieert
-- de database naar een ander bestand terwijl de app 'm nog gebruikt,
-- zonder dat de bron op slot gaat voor schrijvers (in tegenstelling tot
-- een losse bestandskopie van het .db-bestand).
--
-- sqlite-simple zelf heeft deze API niet; we gaan via 'connectionHandle'
-- naar de onderliggende direct-sqlite 'Database' — expliciet toegestaan
-- door sqlite-simple voor precies dit soort functionaliteit.
module Db.Backup
  ( backupTo
  ) where

import Control.Exception (bracket)
import qualified Data.Text as Text
import Database.SQLite.Simple (Connection, connectionHandle)
import qualified Database.SQLite3 as Raw

-- | Maakt een consistente kopie van de database naar het gegeven pad.
backupTo :: Connection -> FilePath -> IO ()
backupTo conn destPath =
  bracket (Raw.open (Text.pack destPath)) Raw.close $ \dest ->
    bracket
      (Raw.backupInit dest "main" (connectionHandle conn) "main")
      Raw.backupFinish
      stepUntilDone
  where
    stepUntilDone backup = do
      result <- Raw.backupStep backup (-1) -- -1: zoveel mogelijk pagina's in één keer
      case result of
        Raw.BackupDone -> pure ()
        Raw.BackupOK   -> stepUntilDone backup
