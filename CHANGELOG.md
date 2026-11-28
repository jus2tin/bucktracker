# Changelog for `bucktracker`

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to the
[Haskell Package Versioning Policy](https://pvp.haskell.org/).

## [Unreleased]

### Added
- **Zero-based / envelope budgeting domain (`Domain.*`):** Integer-cent `Cents` (`Int64`), sealed `Account` (`Checking`, `Savings`, `Cash`, `Tracking`), `CategoryGroup`/`Category`, and `YearMonth` smart constructors, closed `Categorization` sum type (`Categorized (NonEmpty TransactionLine)`, `Inflow`, `TransferLeg`), `clearedBalance` reconciliation, and multi-month YNAB rollover (`rolloverCategoryMonth`, `rolloverMonths`) verified by QuickCheck conservation laws.
- **SQLite persistence layer (`Db.*` & `migrations/0001_initial.sql`):** Auto-applied UTF-8 `.sql` migrations via Cabal `data-files`, `resource-pool` connection management with WAL + `foreign_keys = ON`, explicit `FromRow`/`ToField` instances, and online backup support (`Db.Backup`).
- **Zero-build Frontend & UX Foundation (`/static/*`, Pico CSS, HTMX, Alpine.js CSP):**
  - Locally vendored, offline-ready `pico.min.css` (v2.1.1), `app.css`, `htmx.min.js` (2.0.3), `alpine-csp.min.js` (`@alpinejs/csp` 3.17.5), and `app.js` served at `/static/*` with zero Node/npm build pipeline and zero inline `<style>` tags (`htmx-config` `includeIndicatorStyles: false`).
  - Inline click-to-edit **`Assigned`** cells on `/budget` (`Enter`/`change` to save via HTMX, `Escape` to cancel), supporting negative assignments to return rolled-over funds to Ready to Assign, grouped under `CategoryGroup` headers with `Carried In` visibility.
  - Arbitrary-length (`1..N`) dynamic **split transaction editor** with live integer-cent `Unallocated` calculation, category refunds/credits via negative split lines, and `<details>` entry drawers with global keyboard shortcuts (`n`, `i`, `t`, `Escape`).
  - Two-step **account reconciliation** (`Clear`/`Unclear` register toggle + statement balance reconciliation on `/accounts` with live `Cleared − Statement = Difference` preview, including negative/liability balances).
  - Full **transaction delete & edit** workflows (`deleteTransaction`, `updateInflow`, `updateSpending`, `updateTransfer`), atomically replacing/deleting paired transfer legs while locking `Reconciled` transactions against modification.
  - **Month navigation & account filtering:** `?month=YYYY-MM` Prev/Next navigation on `/budget` and `/transactions` defaulting to the system's local timezone (`getZonedTime`), plus `Account` register column and `?account=<id>` filtering linked from `/accounts`.
  - **Two-way guarded archiving & onboarding:** `Unarchive` actions and `hx-confirm` prompts across accounts, category groups, and categories; zero-balance / no-active-children archive preconditions; server-side guards blocking new creates/assignments on archived entities; and first-run onboarding banners.

### Fixed
- Bound Warp server strictly to loopback (`127.0.0.1`) rather than all interfaces (`0.0.0.0`).
- Enforced on-budget-only rule for `Categorized` spending in both `Db.Transaction.insertSpending` and `Domain.Budget.categoryActivity` to preserve Invariant 1.
- Fixed HTMX full-page double-nesting on `/budget` and `/transactions` via `Api.Html.pageOrFragment` (`HX-Request` detection) with progressive HTML `<form method="post" action="...">` fallbacks everywhere.
- Extracted shared overflow-safe `Api.Money` codec (`±€100B` bound, `,`/`.` decimal separators, `Integer`-backed `centsToEuroText` fixing `Int64` `minBound` formatting).
- Hardened post-Track-A domain, concurrency, and edit invariants (`AUDIT-01`..`AUDIT-08`): bounded `YearMonth` and ISO dates to `[1900, 2200]`, enforced sibling-leg `Reconciled` locks and per-account status preservation on transfers, preserved `txImportHash` on same-account edits, rejected cross-kind mutations (`TransactionKindMismatch`) and archived reassignments on edits, made `reconcileAccountIfMatches` atomic in a single transaction, and trimmed/length-bounded names (`<= 80`) and payees (`<= 160`) with control-character rejection.
