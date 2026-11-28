# Track E Requirements & Architectural Charter — Recurring Obligations & Fixed Bills (`/recurring`)

- **Date:** 2026-11-27
- **Status:** **Planned Roadmap Charter** *(Full turnkey engineering spec to be authored after Tracks B–D complete)*
- **Author:** Carbon / Gemini (Architect), capturing Product Owner (Justin) requirements
- **Related Decisions:** [`DECISIONS.md` §10 & §13](../../DECISIONS.md), [`docs/phases/phase-02-hardening-and-forecasting.md`](phase-02-hardening-and-forecasting.md)

> **Purpose:** Lock down the core product requirements, domain boundaries, and accounting rules for **Track E (`/recurring`)** now so nothing is lost while Tracks B–D execute, and so earlier schema/domain work never conflicts with this model.

---

## 1. Core Product Insight: Orthogonal Schedule vs. Envelope Placement

A common flaw in budgeting apps is forcing users to create artificial `"Subscriptions"` or `"Fixed Bills"` budget categories — hiding how much they *actually* spend on Entertainment, Sport, Health, or Housing.

Bucktracker decouples **how often and how mandatory a charge is** (`recurring_rules`) from **what area of life the money is spent on** (`categories`):

1. **Natural Category Placement:**
   - Every `recurring_rule` (`amount`, `cadence`: `Monthly | Quarterly | Annual`, `expected_day`, `target_category_id`, payee/matcher) points to its **natural topical budget category**:
     - *Netflix*, *Crunchyroll* → **Entertainment**
     - *Basic-Fit* → **Sport**
     - *Rent / Mortgage*, *Vattenfall / Energy*, *Internet* → **Housing / Utilities**
     - *Zorgverzekering* → **Health**
     - *Gemeentelijke belastingen*, *Wegenbelasting* → **Taxes / Transport**
   - **Why this matters:** Recurring subscriptions directly compete with one-off discretionary purchases inside the same envelope. If *Entertainment* has €50.00 assigned and *Netflix* (€13.99) + *Crunchyroll* (€6.99) claim €20.98, only €29.02 genuinely remains for cinema tickets or games.
2. **Explicit `is_fixed_obligation` Flag (`Bool`):**
   - Distinguishes **non-negotiable baseline bills** (`is_fixed_obligation = True`: rent/mortgage, Dutch mandatory health insurance, energy/water, internet, municipal/vehicle taxes) from **discretionary recurring subscriptions** (`is_fixed_obligation = False`: streaming, gym, app memberships).
   - Gives instant clarity on two fundamentally different numbers without distorting category organization:
     - *"What is my non-negotiable monthly survival baseline?"* (`Fixed Obligations`)
     - *"How much am I spending on cancellable recurring subscriptions?"* (`Discretionary Recurring`)

---

## 2. Core Functional Requirements

### 2.1 Domain & Storage Shape (Preview for Full Spec)

- **Separate `recurring_rules` table** (strictly outside `transactions`, upholding [`DECISIONS.md` §10](../../DECISIONS.md)):
  - `id` (`RecurringRuleId`)
  - `name` / `payee_match` (`Text`, non-empty, trimmed — used both for display and matching imported/logged transactions)
  - `target_category_id` (`CategoryId`, must belong to an active category)
  - `amount` (`Cents`, strictly `> 0` — the full per-cycle bill amount, e.g. €13.99 monthly or €360.00 annual)
  - `cadence` (`Monthly | Quarterly | Annual`)
  - `expected_day` (`Int`, `1..31`, clamped via `fromGregorian` on short months) + `anchor_month` (`Maybe Int`, `1..12`, identifying which calendar month(s) a `Quarterly` or `Annual` bill falls due)
  - `is_fixed_obligation` (`Bool`)
  - `archived_at` (`Maybe UTCTime` — two-way archive/unarchive consistent with `Account` and `Category`)
- **Pure integer-cent sinking-fund accrual math (`Domain.Recurring`):**
  - `Monthly` rule of `C` cents → monthly accrual `= C`.
  - `Quarterly` rule of `C` cents → `1/3` monthly sinking-fund accrual (using remainder-safe integer cent allocation via `Domain.Types.splitEvenly` / ceiling-toward-due-month so 3 months of accruals always sum to **at least `C` cents** on the billing month — never 1–2 cents short!).
  - `Annual` rule of `C` cents → `1/12` monthly sinking-fund accrual (same exact integer-cent conservation guarantee across 12 months).

### 2.2 Dedicated `/recurring` View & Monthly Baseline Summary

Mounted at `GET /recurring?month=YYYY-MM` (defaulting to `localToday`'s month, matching `/budget` and `/transactions`):

1. **Monthly Baseline Summary Cards:**
   - **Mandatory Fixed-Obligation Baseline (`€/month`):** Sum of monthly amounts + `1/3` quarterly accruals + `1/12` annual accruals across all active rules with `is_fixed_obligation == True`.
   - **Discretionary Subscriptions (`€/month`):** Sum of monthly + pro-rata quarterly/annual accruals across all active rules with `is_fixed_obligation == False`.
   - **Combined Monthly Recurring Footprint (`€/month`)** & **Remaining Unfunded This Month (`€`)**.
2. **Recurring Rules Register (Grouped into *Fixed Obligations* vs. *Discretionary Subscriptions*):**
   - Columns: `Name | Category | Cadence & Expected Day | Cycle Amount | Monthly Accrual | Status`.
   - **Derived Monthly Status (`Paid` / `Funded` / `Due`):**
     - **`Paid`:** A matching `Categorized` outflow in `target_category_id` (matched by case-insensitive `payee_match` substring — e.g. from Track C's ABN AMRO `SEPA Incasso` / card import — or explicit rule match) has already posted in the viewed billing cycle.
     - **`Funded`:** Not yet paid in this cycle, and the target category's `cmAssigned` / `available` in the viewed month already covers the required recurring accrual(s) targeting that category.
     - **`Due`:** Unpaid in a due/active month and the target category's funding is below its required recurring threshold.

### 2.3 One-Click "Fund Recurring" Action (`POST /recurring/fund`)

Eliminates tedious manual entry across 10–20 budget rows at the start of every month:

- **Two clear action modes:**
  1. **Fund Fixed Obligations** (tops up only `is_fixed_obligation == True` rules — ideal when budgeting a partial paycheck or tight month).
  2. **Fund All Recurring** (tops up both fixed obligations and discretionary subscriptions).
- **Multi-rule category aggregation & idempotency rule (Crucial!):**
  - Multiple recurring rules can target the **same** category (e.g., *Netflix* €13.99 + *Crunchyroll* €6.99 both target *Entertainment* → combined monthly recurring requirement = **€20.98**).
  - For each target `CategoryId` with required monthly accrual sum $R$:
    - If current `cmAssigned < R` (or sinking-fund target isn't yet met), top up `cmAssigned` to $R$ (`max cmAssigned R`, or shortfall top-up — exact formula to be locked down in the full Track E spec so pre-existing discretionary buffer in `cmAssigned` is never *reduced*!).
    - **Idempotent:** Clicking **"Fund Recurring"** twice in a row in the same month is a guaranteed no-op (`€0.00` extra assigned on the second click).
  - Executes atomically inside one `withImmediateTransaction` (`Db.Pool`) and updates `Ready to Assign` via standard `Db.Assignment.setAssignment` rows — **zero special-case changes to `Domain.Budget`'s 5 core invariants!**

---

## 3. Open Design Items to Lock Down When Authoring the Full Track E Spec (Post-Tracks B–D)

1. **Top-Up Formula Nuance (`cmAssigned` vs. `available`):** Decide whether *"Fund Recurring"* ensures `cmAssigned >= sum(monthlyAccrualsForCategory)` for that month (cleanest and most predictable for quarterly/annual sinking funds that accumulate `cmCarriedIn` month over month!) vs. topping up `available` for purely monthly bills. *(Note: `cmAssigned >= sum(monthlyAccruals)` works uniformly for Monthly, Quarterly, and Annual sinking funds!)*
2. **Transaction Matching Precision:** Whether `Paid` status relies purely on deterministic `(target_category_id, payee_match substring)` over `Categorized` lines in the month (zero extra FK columns on `transactions`) or an optional `recurring_rule_id` link during Track C's Import Preview.
3. **Synergy with `/forecast` (`DECISIONS.md` §10):** How `Domain.Projection` consumes `RecurringRule` directly so users don't have to enter recurring bills twice across `/recurring` and `/forecast`.
