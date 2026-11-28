# Bucktracker — Project Governance & Collaboration Paper Trail

This directory maintains the durable project management, architectural review, and phase-planning paper trail for **Bucktracker**.

## Team Roles & Workflow

Bucktracker is built through a structured three-role collaboration loop:

| Role | Actor | Responsibility & File Ownership |
|---|---|---|
| **Product Owner** | Justin | Sets product vision, scope boundaries, user-experience priorities, and final milestone sign-off. |
| **Architect** | Carbon / Gemini ([`GEMINI.md`](../GEMINI.md)) | Owns **all** Markdown specs (`docs/**`), adversarial audits, `ARCHITECTURE.md`, `DECISIONS.md`, `CHANGELOG.md`, `README.md`, `.github/workflows/*`, and synthetic fixtures (`test/fixtures/*`). Never edits `.hs`, `.js`, `.css`, or build manifests. |
| **Developer** | Claude ([`CLAUDE.md`](../CLAUDE.md)) | Owns **exclusively** executable code (`src/**`, `app/**`, `migrations/*.sql`, `static/**`), tests (`test/**/*.hs`), and manifests (`package.yaml`, `stack.yaml`). Never edits Markdown docs unless explicitly prompted. |

### The Milestone Loop

```text
  1. Spec        Architect + PO lock down engineering spec (docs/phases/) & fixtures (test/fixtures/)
       │
       ▼
  2. Build       Developer implements code + tests (stack test --fast) in atomic commits
       │
       ▼
  3. Audit       Architect runs adversarial review (docs/reviews/) -> Developer resolves AUDIT tickets
       │
       ▼
  4. Docs/Gate   Architect updates ARCHITECTURE.md, DECISIONS.md, CHANGELOG.md & docs/handoffs/
       │
       ▼
  5. Sign-Off    PO decides Go / No-Go and advances to the next Track
```

---

## Documentation Map: Living Docs vs. Paper Trail

To keep root documentation crisp while preserving a full historical audit trail, documents are separated by lifecycle:

### Living Canonical Specifications (Repository Root)
- **[`README.md`](../README.md)** — Quickstart, configuration, and entry-point navigation.
- **[`CLAUDE.md`](../CLAUDE.md)** — Engineering standards, compiler discipline, domain rules summary, and collaboration rules (auto-loaded by Claude Code).
- **[`ARCHITECTURE.md`](../ARCHITECTURE.md)** — The "Owner's Manual" describing how the system works *right now* and where to change things. Updated in the same commit whenever routes, tables, or domain rules change.
- **[`DECISIONS.md`](../DECISIONS.md)** — Durable Architectural Decision Records (ADRs) explaining *why* core domain and technical choices were made.
- **[`CHANGELOG.md`](../CHANGELOG.md)** — User-visible changes per tagged version.

### Chronological Paper Trail & Operational Guides (`docs/`)
- **[`docs/RUNBOOK.md`](RUNBOOK.md)** — Daily-driver operator's guide (SQLite DB + WAL sidecar rules, online backup & step-by-step restore, `PRAGMA integrity_check` & SQL invariant queries, isolated scratch DB testing).
- **`docs/reviews/`** — Point-in-time adversarial and architectural audits by the Architect (`YYYY-MM-DD-<milestone>-review.md`, immutable snapshots):
  - [`reviews/2026-11-27-mvp-adversarial-review.md`](reviews/2026-11-27-mvp-adversarial-review.md) — Phase 1 MVP audit
  - [`reviews/2026-11-27-post-track-a-audit.md`](reviews/2026-11-27-post-track-a-audit.md) — Post-Track-A security & edge-case audit (`AUDIT-01`..`AUDIT-08` ticket queue)
- **`docs/phases/`** — Actionable implementation plans & turnkey engineering specs:
  - [`phases/phase-02-hardening-and-forecasting.md`](phases/phase-02-hardening-and-forecasting.md) — Master Phase 2+ roadmap & checklist (Tracks A–E)
  - [`phases/track-b-spec.md`](phases/track-b-spec.md) — Track B Engineering Spec (SQLite WAL concurrency, CSRF/CSP middleware, online backups, CI)
  - [`phases/track-c-abn-amro-import-spec.md`](phases/track-c-abn-amro-import-spec.md) — Track C ABN AMRO Importer Spec (`CAMT.053` + `.TAB`, window-invariant `ImportHash` + `test/fixtures/abn-amro/`)
  - [`phases/track-d-reporting-spec.md`](phases/track-d-reporting-spec.md) — Track D Reporting Spec (Zero-JS inline SVG Net-Worth & Monthly Spending `/reports`, alongside `/forecast`)
  - [`phases/track-e-recurring-spec.md`](phases/track-e-recurring-spec.md) — Track E Recurring Obligations & Fixed Bills Charter (`/recurring`, `is_fixed_obligation`, sinking-fund accruals & one-click "Fund Recurring"; full spec after Tracks B–D)
- **`docs/handoffs/`** — Milestone completion notes and release gate logs (`YYYY-MM-DD-<slug>.md`), using [`TEMPLATE.md`](handoffs/TEMPLATE.md):
  - [`handoffs/2026-11-27-phase-02-track-a.md`](handoffs/2026-11-27-phase-02-track-a.md) — Track A exit-gate handoff

---

## Phase Numbering Clarification

During the initial MVP build, [`DECISIONS.md`](../DECISIONS.md) used "Phase 1 / 2 / 3" internally to refer to the three horizontal code layers of v0.1 (`Domain` → `Db` → `Api`). From the product level onward, **Product Phases** track end-to-end milestones:

| Product Phase | Target Version | Scope Summary | Plan / Review Artifacts |
|---|---|---|---|
| **Phase 1 (MVP Candidate)** | `v0.1.0-rc` | Initial vertical build: `Domain` (1A), `Db` (1B), and `Api`/HTMX UI (1C) for Accounts, Categories, Transactions, Splits, Reconciliation, and Budget Rollover. | Review: [`reviews/2026-11-27-mvp-adversarial-review.md`](reviews/2026-11-27-mvp-adversarial-review.md) |
| **Phase 2+ (UX, Hardening, Import, Reporting & Recurring)** | `v0.1.0` → `v0.3.0` | **Track A:** Frontend & UX Foundation (`/static/*`, Pico CSS, Alpine.js micro-interactions, inline `/budget` editing, CRUD/month/archive fixes).<br>**Track B:** Security middleware, SQLite WAL concurrency, online backups, zero-warning CI (`v0.1.0` sign-off gate).<br>**Track C:** ABN AMRO (`CAMT.053` & `.TAB`) bank statement import.<br>**Track D:** Zero-JS Net-Worth & Spending `/reports` + `/forecast` projections.<br>**Track E:** Recurring obligations & fixed bills (`/recurring`, `is_fixed_obligation` baseline, `1/3` & `1/12` sinking-fund accruals, one-click *"Fund Recurring"*). | Master Plan: [`phases/phase-02-hardening-and-forecasting.md`](phases/phase-02-hardening-and-forecasting.md) |
