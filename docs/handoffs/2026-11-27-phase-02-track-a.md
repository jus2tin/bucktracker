# Handoff: Phase 2 — Track A (Frontend & UX Foundation + MVP Blocker Remediation)

- **Date:** 2026-11-27
- **Author:** Carbon / Gemini (Architect), documenting Claude's Track A implementation (`GEMINI.md` workflow)
- **Phase Plan:** [`docs/phases/phase-02-hardening-and-forecasting.md`](../phases/phase-02-hardening-and-forecasting.md) (Track A: Steps 1–6)
- **Target Branch / PRs:** PRs #8, #9, #10, #11 merged to `main`; Step 5 committed (`8548275`, `e0570d2`) + Step 6 ready in working tree on `feat/phase2-track-a-step5-register-completeness`

## Summary of Completed Steps

- [x] **Step 1 — Servant `/static/*` & Vendored Assets** (`PR #8`, `3505505`): Vendored `pico.min.css` (v2.1.1), `htmx.min.js` (2.0.3), `alpine-csp.min.js` (`@alpinejs/csp` 3.17.5), and `static/app.js` via Cabal `data-files` (`serveDirectoryWith` + `NoMaxAge`); added `Api.StaticSpec`.
- [x] **Step 2 — Semantic Pico Layout, `S-1` HTMX Fragment Fix & Form Fallbacks** (`PR #9`, `074e27b`): Semantic `<header>`/`<main class="container">` layout in `Api.Html.page`, unified `pageOrFragment` inspecting `HX-Request`, and progressive `method="post" action="..."` forms across all pages.
- [x] **Step 3 — Shared `Api.Money` Codec & Inline `/budget` Editing** (`PR #10`, `c359ce1`): Extracted overflow-safe `Api.Money` (`parseSignedEuros`, `parseNonZeroSignedEuros`, `parsePositiveEuros`, `Integer`-backed `centsToEuroText`), replaced detached budget form with Alpine CSP `inlineAssign` click-to-edit cells, added `Carried In` column, grouped under `CategoryGroup` headers, and hid zero-balance archived categories.
- [x] **Step 4 — Alpine.js Micro-Interactions: Dynamic Splits, Live Reconciliation & Shortcuts** (`PR #11`, `ab516ac`): Manual `FromForm` (`lookupAll`) + `splitEditor` (`1..N` dynamic rows, integer-cent `Unallocated` preview, signed category refunds), signed inflows, signed reconciliation with live `reconcileCalc` difference preview, and `<details>` entry drawers with `n`/`i`/`t`/`Escape` keyboard shortcuts.
- [x] **Step 5 — Transaction Delete/Edit, Month Navigation & Register Completeness** (`8548275`, `e0570d2`): Added `CannotModifyReconciledTransaction`, `deleteTransaction`, `updateInflow`/`updateSpending`/`updateTransfer` via `withReplaceable`, local-timezone `localToday` + `?month=YYYY-MM` navigation on `/budget` and `/transactions`, `Account` column, and `?account=<id>` register filter.
- [x] **Step 6 — Two-Way Archiving, Server-Side Entity Guards & Doc Sync** (ready in working tree):
  - Code & Specs (Claude): idempotent `archive*`/`unarchive*`, `hx-confirm` on archive buttons, zero-balance / no-active-children guards (`currentlyAvailable`, `archiveAccountHandler`, `archiveCategoryGroupHandler`), `ArchivedCategoryGroup` + create/assign server-side guards, on-budget-only spending picker (`accountChoices True`), hidden `reconcileCell` on archived accounts, and first-run `onboardingBanner`s.
  - Documentation & Release Prep (Carbon): updated `ARCHITECTURE.md`, `DECISIONS.md` §11, and `CHANGELOG.md`.

## Action for Claude on Session Reset (Before Committing Step 6)

- [ ] **1-line `package.yaml` fix (Claude-owned manifest):** Set `github: "jus2tin/bucktracker"` (and update the matching `description` URL on line 27) in `package.yaml`, then run `stack test --fast --test-arguments="--format=progress"` once so hpack regenerates `bucktracker.cabal` cleanly and commit Step 6.

## Architectural Notes & Tradeoffs

- `serveDirectoryWith` uses `ssMaxAge = NoMaxAge` rather than `serveDirectoryWebApp`'s 1-year cache header so unhashed `/static/app.js` updates take effect immediately across rebuilds.
- Entry and row-edit forms on `/transactions` use native HTML `<details>`/`<summary>` drawers rather than `<dialog>` modals — zero focus-trap edge cases and full progressive-enhancement compatibility.
- Mutations on `/transactions` re-render the default view (today's local month, unfiltered) as a deliberate v0.1 simplification documented in `ARCHITECTURE.md`.

## Next Queue: Post-Track-A Audit Tickets & Track B (`v0.1.0` Release Gate)

Immediately after committing Step 6, execute [`docs/reviews/2026-11-27-post-track-a-audit.md`](../reviews/2026-11-27-post-track-a-audit.md) (`AUDIT-01`..`AUDIT-08`) together with [`docs/phases/track-b-spec.md`](../phases/track-b-spec.md):
1. **`AUDIT-01` (Critical):** Bound `YearMonth` years (`1900..2200`) to prevent `?month=99999999-01` OOM / `maxBound` infinite loop.
2. **`AUDIT-02` (Critical):** Check *both* legs of a transfer for `Reconciled` status in `withReplaceable` and preserve individual leg statuses on `updateTransfer`.
3. **`AUDIT-03` (High):** Preserve `txImportHash` on `updateInflow`/`updateSpending`, enforce matching `Categorization` kind on `edit-*`, and reject mismatched split array lengths.
4. **`AUDIT-04` (High):** Extend `archiveCategoryHandler`'s `currentlyAvailable` check to future months `>= ym` so future-assigned funds cannot be stranded.
