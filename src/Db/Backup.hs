-- | Backup via SQLite's online backup API (see DECISIONS.md §7): copies
-- the database to another file while the app is still using it, without
-- locking the source against writers (unlike a plain file copy of the
-- .db file).
--
-- sqlite-simple itself doesn't have this API; we go via
-- 'connectionHandle' to the underlying direct-sqlite 'Database' —
-- explicitly sanctioned by sqlite-simple for exactly this kind of
-- functionality.
module Db.Backup
  ( backupTo
  ) where

import Control.Exception (bracket)
import qualified Data.Text as Text
import Database.SQLite.Simple (Connection, connectionHandle)
import qualified Database.SQLite3 as Raw

-- | Makes a consistent copy of the database at the given path.
backupTo :: Connection -> FilePath -> IO ()
backupTo conn destPath =
  bracket (Raw.open (Text.pack destPath)) Raw.close $ \dest ->
    bracket
      (Raw.backupInit dest "main" (connectionHandle conn) "main")
      Raw.backupFinish
      stepUntilDone
  where
    stepUntilDone backup = do
      result <- Raw.backupStep backup (-1) -- -1: as many pages as possible at once
      case result of
        Raw.BackupDone -> pure ()
        Raw.BackupOK   -> stepUntilDone backup
