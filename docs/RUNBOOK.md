# Bucktracker — Daily-Driver Operator's Runbook

This runbook covers day-to-day operation of a local Bucktracker instance: where your ledger lives on disk, how SQLite WAL sidecar files behave, how to back up and restore safely without corrupting data, how to verify database and accounting integrity, and how to test or reset safely.

---

## 1. Starting the App & Locating Your Data

### Default Database Locations
When `BUCKTRACKER_DB_PATH` is not set, Bucktracker resolves the platform XDG data directory via `System.Directory.getXdgDirectory XdgData "bucktracker"` (`src/Config.hs`):

| Platform | Default Database Path | Default Backup Directory (Track B+) |
|---|---|---|
| **Windows** | `%APPDATA%\bucktracker\bucktracker.db`<br>*(typically `C:\Users\<You>\AppData\Roaming\bucktracker\bucktracker.db`)* | `%APPDATA%\bucktracker\backups\` |
| **Linux** | `${XDG_DATA_HOME:-~/.local/share}/bucktracker/bucktracker.db` | `${XDG_DATA_HOME:-~/.local/share}/bucktracker/backups/` |
| **macOS** | `~/Library/Application Support/bucktracker/bucktracker.db` | `~/Library/Application Support/bucktracker/backups/` |

### Environment Variables
- `BUCKTRACKER_PORT` — Loopback HTTP port on `127.0.0.1` (default: `8080`). The server binds strictly to `127.0.0.1` and is never exposed on LAN interfaces.
- `BUCKTRACKER_DB_PATH` — Explicit path to the SQLite `.db` file. Parent directories are created automatically on first run.

### Crucial Rule: Understand SQLite WAL Sidecar Files
Bucktracker runs SQLite in **Write-Ahead Logging (`WAL`)** mode. While the server is running (or after an unclean kill), three files exist side by side:
1. `bucktracker.db` — Main database pages
2. `bucktracker.db-wal` — Uncheckpointed committed transactions!
3. `bucktracker.db-shm` — Shared-memory WAL index

> **WARNING — Never copy, move, or delete `bucktracker.db` by itself while `bucktracker.db-wal` exists!**
> Recent transactions live in `.db-wal` until SQLite checkpoints them into `.db`. Copying `.db` alone while the app is open produces an incomplete or corrupt snapshot, and replacing `.db` while leaving an old `.db-wal` behind **will corrupt the database**. Always use the Online Backup workflow (§2) or stop the server completely first.

---

## 2. Backup & Restore Workflow

### 2.1 Taking a Safe Backup

#### Option A — Online Backup While Running (Recommended)
Uses SQLite's online backup API (`src/Db/Backup.hs`), which copies a consistent point-in-time snapshot into a standalone, self-contained `.db` file (with no `-wal` needed on the backup) even while Bucktracker is running:
- **Web UI (Track B Step 11+):** Click **Create Backup** on `/accounts` → writes `<dbDir>/backups/bucktracker-YYYYMMDD-HHMMSS.db` and runs `PRAGMA integrity_check` automatically.
- **CLI (Track B Step 11+):**
  ```powershell
  # Writes to default backups/ directory
  stack exec bucktracker-exe -- --backup

  # Or write to a specific external/cloud-synced folder (e.g. OneDrive / USB)
  stack exec bucktracker-exe -- --backup "D:\Backups\bucktracker-2026-11-27.db"
  ```
- **SQLite CLI alternative (works today on any SQLite ≥ 3.27):**
  ```powershell
  sqlite3 "$env:APPDATA\bucktracker\bucktracker.db" "VACUUM INTO 'D:/Backups/bucktracker-manual.db';"
  ```

#### Option B — Offline File Copy (Server Stopped)
1. Stop `bucktracker-exe` (`Ctrl+C`) so SQLite folds `.db-wal` cleanly into `.db`.
2. Verify `bucktracker.db-wal` is either absent or `0` bytes (if non-empty, copy **all three** `.db`, `.db-wal`, and `.db-shm` together, or fold first with `sqlite3 bucktracker.db "PRAGMA wal_checkpoint(TRUNCATE);"`).
3. Copy `bucktracker.db` to your backup destination.

### 2.2 Restoring from a Backup (Step-by-Step)

1. **Stop the Bucktracker server completely** (`Ctrl+C` and confirm no `bucktracker-exe` process is running).
2. **Verify the backup file *before* restoring it:**
   ```powershell
   sqlite3 "D:\Backups\bucktracker-2026-11-27.db" "PRAGMA integrity_check; PRAGMA foreign_key_check;"
   ```
   Confirm `integrity_check` prints `ok` and `foreign_key_check` prints zero rows.
3. **Quarantine (do not immediately delete) the current live files** — including both WAL sidecars:
   ```powershell
   $dir = "$env:APPDATA\bucktracker"
   $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
   if (Test-Path "$dir\bucktracker.db")     { Move-Item "$dir\bucktracker.db"     "$dir\bucktracker.pre-restore-$stamp.db" }
   if (Test-Path "$dir\bucktracker.db-wal") { Move-Item "$dir\bucktracker.db-wal" "$dir\bucktracker.pre-restore-$stamp.db-wal" }
   if (Test-Path "$dir\bucktracker.db-shm") { Move-Item "$dir\bucktracker.db-shm" "$dir\bucktracker.pre-restore-$stamp.db-shm" }
   ```
4. **Copy the verified backup into place:**
   ```powershell
   Copy-Item "D:\Backups\bucktracker-2026-11-27.db" "$dir\bucktracker.db"
   ```
5. **Start Bucktracker** (`stack run`). Any newer `.sql` migrations added since the backup was taken will apply automatically on startup.

---

## 3. Database & Financial Integrity Checks

### 3.1 Physical & Referential Integrity
Run via CLI (Track B Step 11+):
```powershell
stack exec bucktracker-exe -- --integrity-check
```
Or directly via `sqlite3`:
```sql
PRAGMA integrity_check;     -- Expected: ok
PRAGMA foreign_key_check;   -- Expected: (empty output)
```

### 3.2 Domain Invariant Sanity Queries (Read-Only SQL)
You can independently audit Bucktracker's core financial invariants directly in `sqlite3` at any time:

```sql
-- 1. Invariant 2: Every transfer must have exactly 2 legs summing to 0 cents
SELECT transfer_id, COUNT(*) AS legs, SUM(amount) AS net_cents
FROM transactions
WHERE kind = 'transfer'
GROUP BY transfer_id
HAVING legs <> 2 OR net_cents <> 0;
-- Expected: 0 rows

-- 2. Invariant 5: Every categorized transaction must have >= 1 split line
SELECT t.id, t.date, t.payee
FROM transactions t
LEFT JOIN transaction_lines tl ON tl.transaction_id = t.id
WHERE t.kind = 'categorized'
GROUP BY t.id
HAVING COUNT(tl.id) = 0;
-- Expected: 0 rows

-- 3. No categorized spending on Tracking accounts
SELECT t.id, a.name
FROM transactions t
JOIN accounts a ON a.id = t.account_id
WHERE t.kind = 'categorized' AND a.type = 'tracking';
-- Expected: 0 rows

-- 4. No transfer mixing On-Budget and Tracking accounts
SELECT t.transfer_id
FROM transactions t
JOIN accounts a1 ON a1.id = t.account_id
JOIN accounts a2 ON a2.id = t.counterpart_account_id
WHERE t.kind = 'transfer'
  AND (a1.type = 'tracking') <> (a2.type = 'tracking');
-- Expected: 0 rows
```

---

## 4. Safe Scratch Testing, Seeding & Resetting

### Running an Isolated Scratch / Demo Ledger (Never Touch Real Data!)
When manually testing UI changes, bank statement imports, or migrations, **always** point `BUCKTRACKER_DB_PATH` (and a separate port if your real instance is running) at a scratch path outside `%APPDATA%\bucktracker`:

```powershell
# PowerShell: spin up a disposable demo instance on port 8081
$env:BUCKTRACKER_PORT = "8081"
$env:BUCKTRACKER_DB_PATH = "$env:TEMP\bucktracker-demo.db"
stack run
```
*(Remember `.gitignore` ignores `*.db`, `*.db-wal`, and `*.db-shm`, though keeping scratch DBs in `$env:TEMP` avoids cluttering the repository working tree.)*

### Cleanly Resetting a Database from Scratch
Bucktracker requires no manual seed script — `Db.Migrations.runMigrations` builds the complete schema automatically whenever the database file does not exist:
1. Stop the server (`Ctrl+C`).
2. Back up first if the file holds anything you might ever want again (§2.1).
3. Delete **all three** files (`bucktracker.db`, `bucktracker.db-wal`, `bucktracker.db-shm`).
4. Start `stack run` — a fresh database is created and migrated automatically.
