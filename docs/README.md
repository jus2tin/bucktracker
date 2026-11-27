# Bucktracker — Project Governance & Collaboration Paper Trail

This directory maintains the durable project management, architectural review, and phase-planning paper trail for **Bucktracker**.

## Team Roles & Workflow

Bucktracker is built through a structured three-role collaboration loop:

| Role | Actor | Responsibility |
|---|---|---|
| **Product Owner** | Justin | Sets product vision, scope boundaries, user-experience priorities, and final milestone sign-off. |
| **Architect** | Gemini | Audits milestones adversarially, guards financial/security invariants, authors step-by-step phase plans, and signs off (or gates) phase transitions. |
| **Developer** | Claude | Executes phase plans in focused, well-tested commits/PRs adhering to [`CLAUDE.md`](../CLAUDE.md), keeps [`ARCHITECTURE.md`](../ARCHITECTURE.md) synchronized, and records completion handoffs. |

### The Milestone Loop

```text
  1. Plan        Architect + PO align on the next phase plan in docs/phases/
       │
       ▼
  2. Build       Developer executes steps in small PRs/commits, updating ARCHITECTURE.md
       │
       ▼
  3. Handoff     Developer writes a brief completion & triage note in docs/handoffs/
       │
       ▼
  4. Review      Architect performs an adversarial review in docs/reviews/
       │
       ▼
  5. Sign-Off    PO decides Go / No-Go (or pulls blockers into the next phase)
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

### Chronological Paper Trail (`docs/`)
- **`docs/reviews/`** — Point-in-time adversarial and architectural audits by the Architect. Files are named `YYYY-MM-DD-<milestone>-review.md` and are **immutable snapshots** once merged (never retroactively edited when bugs are fixed; subsequent reviews verify closure).
- **`docs/phases/`** — Actionable, ordered step-by-step implementation plans (`phase-NN-<slug>.md`) with explicit scope, target files, invariants, and exit gates.
- **`docs/handoffs/`** — Developer milestone completion notes and review-triage logs (`YYYY-MM-DD-<slug>.md`), using [`TEMPLATE.md`](handoffs/TEMPLATE.md). Moving triage checklists and progress logs here keeps `DECISIONS.md` focused on timeless architecture decisions rather than temporary bug backlogs.

---

## Phase Numbering Clarification

During the initial MVP build, [`DECISIONS.md`](../DECISIONS.md) used "Phase 1 / 2 / 3" internally to refer to the three horizontal code layers of v0.1 (`Domain` → `Db` → `Api`). From the product level onward, **Product Phases** track end-to-end milestones:

| Product Phase | Target Version | Scope Summary | Plan / Review Artifacts |
|---|---|---|---|
| **Phase 1 (MVP Candidate)** | `v0.1.0-rc` | Initial vertical build: `Domain` (1A), `Db` (1B), and `Api`/HTMX UI (1C) for Accounts, Categories, Transactions, Splits, Reconciliation, and Budget Rollover. | Review: [`reviews/2026-11-27-mvp-adversarial-review.md`](reviews/2026-11-27-mvp-adversarial-review.md) |
| **Phase 2 (UX Foundation, Hardening & Forecasting)** | `v0.1.0` → `v0.2.0` | **Track A:** Frontend & UX Foundation (`/static/*`, Pico CSS, Alpine.js micro-interactions, inline `/budget` editing, HTMX/CRUD/month fixes).<br>**Track B:** Security middleware, SQLite WAL concurrency, online backups, **CSV/CAMT.053 bank import**, zero-warning CI.<br>**Track C:** Scheduled transactions & pure cash-flow projections (`/forecast`). | Plan: [`phases/phase-02-hardening-and-forecasting.md`](phases/phase-02-hardening-and-forecasting.md) |
