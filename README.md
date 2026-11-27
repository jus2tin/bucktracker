# Bucktracker

A personal zero-based / envelope budget and money tracker (a YNAB
alternative), built in Haskell with Servant, Lucid and HTMX. Runs
locally, no account, no cloud, no auth.

## Quickstart

Requires [Stack](https://docs.haskellstack.org/) (resolver
`lts-24.68`, GHC 9.10.3 — Stack installs the right GHC for you).

```sh
stack build --fast   # compile (library + executable)
stack test            # hspec + QuickCheck: Domain, Db, Api
stack run              # start the server (http://localhost:8080)
```

The database and its migrations are set up automatically on first run
— there's nothing to seed or initialize by hand.

## Configuration

Both environment variables are optional; sensible defaults apply if
you set neither.

| Variable | Default | Meaning |
|---|---|---|
| `BUCKTRACKER_PORT` | `8080` | HTTP port the Warp server listens on (loopback-only, `127.0.0.1` — see `DECISIONS.md` §8, H-1/H-2) |
| `BUCKTRACKER_DB_PATH` | `%APPDATA%\bucktracker\bucktracker.db` on Windows (the XDG data directory otherwise) | Path to the SQLite database file |

## Where to go next

- **[`ARCHITECTURE.md`](ARCHITECTURE.md)** — the "Owner's Manual": how
  a browser click becomes a database write and back, how the
  budgeting math (Ready to Assign, month rollover, splits, transfers,
  reconciliation) actually works, and a quick-reference table for
  "where do I change X?".
- **[`DECISIONS.md`](DECISIONS.md)** — the full reasoning behind every
  technical choice, known v0.1 limitations, and what's deliberately
  still open or deferred.
- **[`CLAUDE.md`](CLAUDE.md)** — the coding standards and conventions
  this codebase holds itself to (total functions only, type-safe IDs
  and money, where each kind of code belongs).
