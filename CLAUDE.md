# Project: Bucktracker
Personal zero-based / envelope budget and money tracker (YNAB alternative) built in Haskell with Servant.

## Language
This is an English-language project: code, identifiers, comments, commit messages, and PR descriptions are all written in English, regardless of what language the conversation driving the work happens to be in.

## Two-Model File-Ownership Firewall (Strict)

Bucktracker uses an explicit two-model workflow: **Claude (Developer)** writes all executable code, tests, static assets, and build manifests; **Carbon / Gemini (Architect — see `GEMINI.md`)** owns all Markdown specifications, audits, architecture/decision docs, release notes, CI workflows, and synthetic fixtures.

### Claude's Owned Paths
- `src/**` — Domain, Database, API, and Config Haskell modules.
- `app/**` — Executable entry point (`app/Main.hs`).
- `migrations/*.sql` — Numbered SQLite schema migrations.
- `test/**/*.hs` — All `hspec` / `QuickCheck` specs (`*Spec.hs`), test harnesses (`Setup.hs`), and generators (`Gen.hs`).
- `static/**` — Vendored and local `.css` / `.js` assets (`app.js`, `app.css`, `pico.min.css`, `htmx.min.js`, `alpine-csp.min.js`).
- `package.yaml` (plus hpack-generated `bucktracker.cabal`) and `stack.yaml`.

### Forbidden Paths (Hands Off Unless Explicitly Prompted)
- **Do NOT create or edit Markdown documentation:** `docs/**`, `CHANGELOG.md`, `DECISIONS.md`, `ARCHITECTURE.md`, `README.md`, `GEMINI.md`, or `.github/workflows/*` unless a prompt explicitly asks you to.
- Carbon updates `ARCHITECTURE.md`, `DECISIONS.md`, `CHANGELOG.md`, and `docs/handoffs/*` after your commits. Read `docs/phases/*` (specs), `docs/reviews/*` (audit tickets), `ARCHITECTURE.md`, and `DECISIONS.md` as read-only inputs.

## Tech Stack & Libraries
- **Build tool:** Stack, resolver `lts-24.68` (GHC 9.10.3).
- **Web framework:** Servant (`servant-server`, `warp`).
- **Database:** SQLite via `sqlite-simple` — hand-written, numbered `.sql` migrations and explicit `FromRow`/`ToRow` instances. No `persistent`/`beam`/`selda`, no TemplateHaskell.
- **JSON:** `aeson` (use `Generic` + `DerivingVia` or explicit instances, no `TemplateHaskell`).
- **Frontend:** Servant + Lucid + HTMX + Pico CSS + Alpine.js (`@alpinejs/csp`). Server-rendered semantic HTML with locally vendored static assets (`static/`, served via `/static/*`), no npm/JS build step. Alpine.js is strictly for ephemeral local UI micro-interactions (integer-cents previews, dynamic split rows, inline-edit/drawer toggles, shortcuts) — never persistent state, never dynamic string interpolation inside `x-*` attributes (use `data-*` attributes instead), and never floating-point currency math (see `DECISIONS.md` §12).
- **Auth:** No auth in v0.1 (binds to `127.0.0.1` loopback only). Handlers run in `ReaderT AppEnv Handler` (via `hoistServer`) so they're testable without a running server.
- **Config:** Env vars. Defaults: port `8080`, SQLite path `%APPDATA%\bucktracker\bucktracker.db` on Windows (XDG data dir elsewhere).
- **Text & Time:** Always `Data.Text` (strict) and `Data.Time` (`UTCTime` / `Day`). No `String` except at the edges for CLI/config.

## Architecture & Directory Structure
- `app/Main.hs`: Entry point, loads config, sets up the DB connection pool and starts the Warp server.
- `src/Api/`: Servant API type definitions and route handlers (keep thin, HTTP translation only).
- `src/Domain/`: Pure business logic, domain types, validation and calculations (no `IO` or DB calls).
- `src/Db/`: Database queries and schema definitions.
- `test/`: `hspec` + `QuickCheck` tests (`test/**/*Spec.hs`), plus read-only golden fixtures in `test/fixtures/`.
- `docs/`: Architect-owned specs (`docs/phases/*`), adversarial audit tickets (`docs/reviews/*`), handoffs (`docs/handoffs/*`), and runbook (`docs/RUNBOOK.md`).

## Coding Standards (Strict)
- **Total functions only:** NEVER use `head`, `tail`, `fromJust`, `read`, or `error` in production code. Use pattern matching, `Maybe`, `Either`, or `NonEmpty`.
- **Type safety:** Use `newtype` wrappers for IDs (`AccountId`, `CategoryId`, `CategoryGroupId`, `TransactionId`, `TransferId`) and money amounts (`Cents` as `Int64`, NEVER `Double` or `Float` for currency). Make illegal states unrepresentable wherever possible (e.g. `NonEmpty` for split lines) instead of validating them.
- **Language extensions:** `language: GHC2021` + `default-extensions`: `OverloadedStrings`, `StrictData`, `DeriveGeneric`, `DataKinds`, `TypeOperators`, `DerivingStrategies`, `DerivingVia`, `DeriveAnyClass` (in `package.yaml`).
- **Compiler flags:** `-Wall -Wmissing-export-lists -Wunused-packages` locally; `-Werror` in CI once Track B clears remaining warnings.
- **Error handling:** Use `ExceptT` / `ServantError` only in the API layer; in the domain, pure `Either DomainError a` (see `src/Domain/Error.hs`), or, where a value can never be invalid, a plain total function.
- **In-code Haddock comments:** Every exported function in `src/Domain/` and `src/Db/` gets a Haddock comment (`-- |`) explaining *why* it exists and any invariant it upholds — not what it does (the type signature + name already say that).

## Execution, Build & Token Hygiene
- **Direct spec/ticket execution:** Execute assigned `docs/phases/*` steps and `docs/reviews/*` `AUDIT-NN` tickets directly into atomic commits.
- **Single-pass test verification:** Run `stack test --fast --test-arguments="--format=progress"` once per completed step/ticket. Never run `stack build` separately beforehand (`stack test` already builds library, executable, and tests). Switch to `--format=specdoc` or `-m "<pattern>"` only when diagnosing a failure.
- **Linter/Formatter (if needed):** `hlint src/ app/ test/` and `ormolu --mode inplace src/`.
- **Targeted reads:** Use `offset`/`limit` line ranges on large modules rather than re-reading whole files repeatedly.
- **Concise status updates:** Keep chat responses brief and factual (what changed, test count/status, commit hash, and any architectural change Carbon should reflect in `ARCHITECTURE.md`).
- **Git commits vs. merges/pushes:** Commit your completed steps atomically on the active branch, then stop — Carbon handles post-commit audit, doc sync, merging into `main`, branch cleanup, and `git push` after Product Owner sign-off (unless a prompt explicitly asks you to push).
- **Fresh sessions per Track:** `/compact` or start a fresh session at Track boundaries.

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
