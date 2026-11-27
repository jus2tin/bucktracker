# Project: Bucktracker
Personal zero-based / envelope budget and money tracker (YNAB alternative) built in Haskell with Servant.

## Language
This is an English-language project: code, identifiers, comments, documentation
(including this file and `DECISIONS.md`), commit messages, and PR descriptions
are all written in English, regardless of what language the conversation
driving the work happens to be in.

See `DECISIONS.md` for the full reasoning behind every choice below,
including known v0.1 limitations and what's deliberately still open.

## Tech Stack & Libraries
- **Build tool:** Stack, resolver `lts-24.68` (GHC 9.10.3).
- **Web framework:** Servant (`servant-server`, `warp`).
- **Database:** SQLite via `sqlite-simple` — hand-written, numbered `.sql` migrations
  and explicit `FromRow`/`ToRow` instances. No `persistent`/`beam`/`selda`, no TemplateHaskell.
- **JSON:** `aeson` (use `Generic` + `DerivingVia` or explicit instances, no `TemplateHaskell`).
- **Frontend:** Servant + Lucid + HTMX + Pico CSS + Alpine.js. Server-rendered semantic HTML with locally vendored static assets (`static/`, served via `/static/*`), no npm/JS build step. Alpine.js is strictly for ephemeral local UI micro-interactions (integer-cents previews, dynamic split rows, inline-edit/modal toggles, shortcuts) — never persistent state or floating-point currency math (see `DECISIONS.md` §12).
- **Auth:** No auth in v0.1 (runs on localhost only). Handlers already run in
  `ReaderT AppEnv Handler` (via `hoistServer`) so they're testable without a running server.
- **Config:** Env vars. Defaults: port `8080`, SQLite path `%APPDATA%\bucktracker\bucktracker.db`
  on Windows (configurable, so a later Linux port is trivial).
- **Text & Time:** Always `Data.Text` (strict) and `Data.Time` (`UTCTime` / `Day`). No `String` except at the edges for CLI/config.

## Architecture & Directory Structure
- `app/Main.hs`: Entry point, loads config, sets up the DB connection and starts the Warp server.
- `src/Api/`: Servant API type definitions and route handlers (keep thin, HTTP translation only).
- `src/Domain/`: Pure business logic, domain types, validation and calculations (no `IO` or DB calls).
- `src/Db/`: Database queries and schema definitions.
- `test/`: `hspec` + `QuickCheck` tests (focused on domain logic and budget invariants), via `hspec-discover`.
- `docs/`: Project collaboration paper trail (see `docs/README.md` for the Product Owner / Architect / Developer workflow):
  - `docs/phases/`: Step-by-step implementation plans and exit gates for the active phase.
  - `docs/reviews/`: Immutable adversarial milestone reviews from the Architect.
  - `docs/handoffs/`: Developer milestone completion and triage notes (use `docs/handoffs/TEMPLATE.md`).

## Coding Standards (Strict)
- **Total functions only:** NEVER use `head`, `tail`, `fromJust`, `read`, or `error` in production code. Use pattern matching, `Maybe`, `Either`, or `NonEmpty`.
- **Type safety:** Use `newtype` wrappers for IDs (`AccountId`, `CategoryId`, `CategoryGroupId`, `TransactionId`, `TransferId`) and money amounts (`Cents` as `Int64`, NEVER `Double` or `Float` for currency). Make illegal states unrepresentable wherever possible (e.g. `NonEmpty` for split lines) instead of validating them.
- **Language extensions:** `language: GHC2021` + `default-extensions`: `OverloadedStrings`, `StrictData`, `DeriveGeneric`, `DataKinds`, `TypeOperators`, `DerivingStrategies`, `DerivingVia`, `DeriveAnyClass` (in `package.yaml`).
- **Compiler flags:** `-Wall -Wmissing-export-lists -Wunused-packages` locally; `-Werror` only in CI (see `DECISIONS.md` §6 for why that isn't on locally yet).
- **Error handling:** Use `ExceptT` / `ServantError` only in the API layer; in the domain, pure `Either DomainError a` (see `src/Domain/Error.hs`), or, where a value can never be invalid, a plain total function.
- **Documentation Standard:**
  - Every exported function in `src/Domain/` and `src/Db/` gets a Haddock comment (`-- |`) explaining *why* it exists and any invariant it upholds — not what it does (the type signature + name already say that). See `Domain.Budget.rolloverCategoryMonth`/`clearedBalance` or `Db.Migrations.applyMigration` for the expected level of detail.
  - Whenever a change adds or changes a page/route, a domain rule, or a database table, update `ARCHITECTURE.md` **in the same commit** — never as a follow-up. A change whose own commit doesn't need an `ARCHITECTURE.md` update (a bug fix, a refactor, a test) can skip this.

## Build & Test Commands
- Build: `stack build --fast`
- Test: `stack test`
- Run: `stack run`
- Linter/Formatter (if present): `hlint src/` and `ormolu --mode inplace src/`

## Context & Token Hygiene
- **One `stack test` per completed step, never `stack build` + `stack test`:** `stack test` already compiles the library, executable, and test suite. Don't run `stack build` separately beforehand — batch edits for a step and run `stack test` once at the end.
- **Quiet test output on passing runs:** default to `stack test --test-arguments="--format=progress"` so a passing run doesn't flood context with dozens of green lines. Switch to `--format=specdoc` or filter with `-m "<pattern>"` only when debugging a specific failure.
- **Read targeted line ranges on large files:** once the module structure is known, use `offset`/`limit` to inspect large files (e.g. `ARCHITECTURE.md`, long test suites) rather than re-reading them whole repeatedly.
- **Concise status updates:** keep chat responses brief and factual (what changed, test status, commit hash). Detailed architectural rationale belongs in `ARCHITECTURE.md`, `DECISIONS.md`, or `docs/handoffs/`.
- **Fresh sessions per Track:** `/compact` or start a new session at Track boundaries — `CLAUDE.md`, `ARCHITECTURE.md`, and `docs/phases/` already hold full state.

## Domain Rules (Bucktracker)
Summary — full detail and edge cases live in `DECISIONS.md` §3-5.

- All amounts are stored and calculated in whole cents (`Int64`), always EUR.
- **Accounts:** `OnBudget` (Checking/Savings/Cash) vs. `Tracking`. Opening balance = an `Inflow` transaction into Ready to Assign, not a separate field.
- **Categories:** two levels (`CategoryGroup -> Category`), period = calendar month.
- **Month rollover:** a positive category balance carries forward; a negative balance resets to 0 and is deducted from the next month's Ready to Assign.
- **Transactions:** expenses negative / income positive. Every transaction is `Categorized` (one or more categories, via `NonEmpty`), `Inflow` (uncategorized, goes to Ready to Assign), or one half of a `Transfer` (two legs, shared `TransferId`, sum = 0, no category impact).
- **Status:** `Uncleared | Cleared | Reconciled`; reconciliation is a pure comparison, not a separate type.
- **Payee:** free-form `Text` on the transaction in v0.1, no separate table.
- **5 hard invariants** (QuickCheck in `test/Domain/`): see `DECISIONS.md` §5.
