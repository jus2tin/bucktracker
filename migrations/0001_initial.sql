-- Phase 2, migration 1: the full v0.1 schema in one go.
--
-- Conventions (see DECISIONS.md §7):
--   * Money always as INTEGER (cents).
--   * YearMonth as two columns (year, month), no parse step needed.
--   * Dates/timestamps as ISO8601 TEXT ("YYYY-MM-DD" / full timestamp),
--     which therefore sort correctly as plain text.
--   * Soft delete via a nullable archived_at timestamp; NULL = active.
--   * CHECK constraints mirror the Haskell sum types as closely as
--     possible (Domain.Transaction.Categorization): a row can't take a
--     shape that's unrepresentable in the domain layer.

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

-- One row per transfer, purely so we can issue a TransferId that's
-- shared by the two transaction legs (avoids a chicken-and-egg problem
-- with the CHECK constraint on transactions below).
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
    -- Only filled in for kind = 'inflow' or 'transfer'; for
    -- 'categorized', the amount follows from the sum of
    -- transaction_lines (see Domain.Transaction.transactionAmount).
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

-- One row per (category, month): "how much has been assigned to this
-- category this month". See Domain.Budget.Assignment/assignedTotal.
CREATE TABLE assignments (
    id          INTEGER PRIMARY KEY,
    category_id INTEGER NOT NULL REFERENCES categories (id),
    year        INTEGER NOT NULL,
    month       INTEGER NOT NULL CHECK (month BETWEEN 1 AND 12),
    amount      INTEGER NOT NULL,
    UNIQUE (category_id, year, month)
);
