-- Fase 2, migratie 1: het volledige v0.1-schema in één keer.
--
-- Conventies (zie DECISIONS.md §7):
--   * Geld altijd als INTEGER (centen).
--   * YearMonth als twee kolommen (year, month), geen parse-stap nodig.
--   * Datums/timestamps als ISO8601-TEXT ("YYYY-MM-DD" / volledige timestamp),
--     sorteren daardoor correct als gewone tekst.
--   * Soft-delete via een nullable archived_at-timestamp; NULL = actief.
--   * CHECK-constraints spiegelen zoveel mogelijk de Haskell-somtypes
--     (Domain.Transaction.Categorization): een rij kan niet een vorm
--     aannemen die in de domeinlaag onrepresenteerbaar is.

PRAGMA foreign_keys = ON;

CREATE TABLE accounts (
    id          INTEGER PRIMARY KEY,
    name        TEXT NOT NULL,
    type        TEXT NOT NULL CHECK (type IN ('checking', 'savings', 'cash', 'tracking')),
    archived_at TEXT
);

CREATE TABLE category_groups (
    id          INTEGER PRIMARY KEY,
    name        TEXT NOT NULL,
    archived_at TEXT
);

CREATE TABLE categories (
    id          INTEGER PRIMARY KEY,
    group_id    INTEGER NOT NULL REFERENCES category_groups (id),
    name        TEXT NOT NULL,
    archived_at TEXT
);

CREATE INDEX idx_categories_group_id ON categories (group_id);

-- Eén rij per transfer, puur om een TransferId te kunnen uitgeven die door
-- de twee transactie-legs gedeeld wordt (voorkomt een kip-ei-probleem met
-- de CHECK-constraint op transactions hieronder).
CREATE TABLE transfers (
    id         INTEGER PRIMARY KEY,
    created_at TEXT NOT NULL
);

CREATE TABLE transactions (
    id                     INTEGER PRIMARY KEY,
    account_id              INTEGER NOT NULL REFERENCES accounts (id),
    date                    TEXT NOT NULL,
    payee                   TEXT NOT NULL,
    status                  TEXT NOT NULL CHECK (status IN ('uncleared', 'cleared', 'reconciled')),
    kind                    TEXT NOT NULL CHECK (kind IN ('categorized', 'inflow', 'transfer')),
    -- Alleen gevuld voor kind = 'inflow' of 'transfer'; voor 'categorized'
    -- volgt het bedrag uit de som van transaction_lines (zie
    -- Domain.Transaction.transactionAmount).
    amount                  INTEGER,
    transfer_id             INTEGER REFERENCES transfers (id),
    counterpart_account_id  INTEGER REFERENCES accounts (id),
    import_hash             TEXT,
    CHECK (
        (kind = 'categorized' AND amount IS NULL AND transfer_id IS NULL AND counterpart_account_id IS NULL)
        OR (kind = 'inflow' AND amount IS NOT NULL AND transfer_id IS NULL AND counterpart_account_id IS NULL)
        OR (kind = 'transfer' AND amount IS NOT NULL AND transfer_id IS NOT NULL AND counterpart_account_id IS NOT NULL)
    )
);

CREATE INDEX idx_transactions_account_id ON transactions (account_id);
CREATE INDEX idx_transactions_date ON transactions (date);
CREATE INDEX idx_transactions_transfer_id ON transactions (transfer_id);

CREATE TABLE transaction_lines (
    id             INTEGER PRIMARY KEY,
    transaction_id INTEGER NOT NULL REFERENCES transactions (id) ON DELETE CASCADE,
    category_id    INTEGER NOT NULL REFERENCES categories (id),
    amount         INTEGER NOT NULL
);

CREATE INDEX idx_transaction_lines_transaction_id ON transaction_lines (transaction_id);
CREATE INDEX idx_transaction_lines_category_id ON transaction_lines (category_id);

-- Eén rij per (categorie, maand): "hoeveel is er deze maand aan deze
-- categorie toegewezen". Zie Domain.Budget.Assignment/assignedTotal.
CREATE TABLE assignments (
    id          INTEGER PRIMARY KEY,
    category_id INTEGER NOT NULL REFERENCES categories (id),
    year        INTEGER NOT NULL,
    month       INTEGER NOT NULL CHECK (month BETWEEN 1 AND 12),
    amount      INTEGER NOT NULL,
    UNIQUE (category_id, year, month)
);
