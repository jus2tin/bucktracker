# Reporting Engineering Specification — Zero-JS Net-Worth & Monthly Spending Reports (`/reports`)

- **Date:** 2026-11-27
- **Author:** Gemini (Architect), for Justin (Product Owner) & Claude (Developer)
- **Related Docs:** [`DECISIONS.md` §§3–5, §12](../../DECISIONS.md), [`ARCHITECTURE.md`](../../ARCHITECTURE.md), [`docs/phases/phase-02-hardening-and-forecasting.md`](phase-02-hardening-and-forecasting.md)

> **Track Placement Note:** In `phase-02-hardening-and-forecasting.md`, Track C covers ABN AMRO Bank Import and Track D covers Scheduled Transactions & `/forecast`. This specification defines the **Reporting workstream (`/reports`)**, which is completely orthogonal to `/forecast` (Reporting summarizes *historical/actual* ledger + tracking data; `/forecast` simulates *future* scheduled templates) and can be scheduled either alongside Track D (`v0.2.0`) or immediately after as **Track E (`v0.2.x` / `v0.3.0`)**.

---

## 1. Architectural Philosophy: Zero-JS Charting & Strict `Int64` Geometry

Most web finance trackers pull in 200+ KB of Chart.js, D3, or ECharts — introducing npm build pipelines, `<canvas>` accessibility blind spots, floating-point rounding drift, and CSP exceptions. Bucktracker takes the opposite path:

1. **Zero JavaScript charting libraries:** Every visualization is **server-rendered inline `<svg>` + semantic Pico HTML `<table>` / `<meter>` / CSS proportion bars**, emitted directly by Haskell's `Lucid` combinators.
2. **Strict CSP compatibility (`style-src 'self'; script-src 'self'`):**
   - Charts use **SVG presentation attributes** (`viewBox`, `width`, `height`, `x`, `y`, `rx`, `points`, `d`, `class`) styled via classes in `/static/app.css` (`stroke: var(--pico-primary)`, `fill: var(--pico-muted-border-color)`), **never inline `style="..."` attributes** (which `style-src 'self'` blocks!).
   - Using Pico CSS custom properties (`var(--pico-...)` and `currentColor`) means every SVG chart adapts to **light mode, dark mode, and print** automatically!
3. **100% integer math — even for SVG coordinates & percentages:**
   - All percentages are computed in **integer basis points (`BasisPoints`, `1 bp = 0.01%`, `10000 bp = 100.00%`)** via `Integer` `quotRem`.
   - SVG viewports use integer coordinate grids (e.g., `viewBox="0 0 1000 260"`), projecting `Cents` onto pixel coordinates via `Integer` division (`(val * chartHeight) \`quot\` rangeSpan`). **`Double` and `Float` remain completely absent from the codebase.**
4. **Accessible & progressive by construction:** Every `<figure>` includes `<svg role="img" aria-labelledby="...">` (`<title>` + `<desc>`) paired with a clean tabular breakdown directly underneath so exact euro figures are always copyable and screen-reader friendly.

---

## 2. Core Reports & Pure Domain Model (`src/Domain/Report.hs`)

Following Bucktracker's ironclad layering rule (`Domain/` imports neither `Db/` nor `Api/`), **all aggregation and time-series math lives in a pure `src/Domain/Report.hs` module**, tested with QuickCheck in `test/Domain/ReportSpec.hs`.

### 2.1 Report 1 — Net Worth Over Time (`OnBudget` Cash + `Tracking` Assets & Liabilities)

This is the primary place where **`OnBudget` accounts (`Checking`, `Savings`, `Cash`) and `Tracking` accounts (investments, brokerage, home equity, mortgage, student loans) unite into one financial picture**:

```haskell
-- | Integer basis points: 10000 == 100.00%, -250 == -2.50%.
newtype BasisPoints = BasisPoints Int64
  deriving stock (Eq, Ord, Show)

data NetWorthPoint = NetWorthPoint
  { nwpMonth               :: YearMonth
  , nwpOnBudgetCash        :: Cents        -- ^ Sum of OnBudget account balances <= month end
  , nwpTrackingAssets      :: Cents        -- ^ Sum of Tracking accounts with balance > 0 at month end
  , nwpTrackingLiabilities :: Cents        -- ^ Sum of Tracking accounts with balance < 0 at month end (<= 0)
  , nwpTotalAssets         :: Cents        -- ^ Positive account balances (OnBudget + Tracking) >= 0
  , nwpTotalDebts          :: Cents        -- ^ Negative account balances (overdrafts + Tracking debts) <= 0
  , nwpNetWorth            :: Cents        -- ^ Exact sum of ALL account balances <= month end
  , nwpMonthlyChange       :: Maybe Cents  -- ^ Nothing for first point in window; else nwpNetWorth - prev
  } deriving stock (Eq, Show)

buildNetWorthSeries
  :: [Account]       -- ^ ALL accounts, BOTH active and archived! (See Invariant R-1 below)
  -> [YearMonth]     -- ^ Ascending range, e.g. trailing 12 months
  -> [Transaction]   -- ^ Full ledger history
  -> [NetWorthPoint]
```

> **CRITICAL Historical Truth Rule (Why Archived Accounts MUST Be Included):**
> Suppose a user held €10,000 in Bank A from January to May, transferred all €10,000 to Bank B in June, and archived Bank A (`balance == €0`).
> - If `buildNetWorthSeries` filtered out archived accounts, **January–May's historical net worth would drop by €10,000 retroactively**!
> - Including **all** accounts (active and archived) keeps January–May at €10,000 (on Bank A) and June onward at €10,000 (on Bank B, with Bank A contributing `€0`). Never filter `isArchived` out of historical net-worth series!

**Visual presentation on `/reports`:**
- Headline KPI cards (`<article>` grid): **Total Net Worth**, **On-Budget Liquid Cash**, **Tracking Investments/Assets**, **Total Debts/Liabilities**, and **Period Change (€ & %)**.
- **Inline SVG Net-Worth Chart (`viewBox="0 0 1000 280"`):**
  - Positive stacked bars per month (On-Budget Cash + Tracking Assets above the zero baseline; Debts extending below the zero baseline when present) overlaid with a crisp `<polyline>` connecting `nwpNetWorth` across months, plus `<title>` hover tooltips on each month's data point (`"2026-11: Net Worth €24,510.00 (+€640.00)"`).
- **Account Snapshot Table:** Current month-end balance per account, grouped into *On-Budget Cash* vs. *Tracking Accounts* (hiding archived accounts whose balance was `€0` throughout the entire selected window).

---

### 2.2 Report 2 — Monthly Spending Breakdown (`CategoryGroup` & `Category`)

Summarizes where money actually went in a chosen month (`?month=YYYY-MM`) or multi-month window (`?from=YYYY-MM&to=YYYY-MM`):

```haskell
data CategorySpending = CategorySpending
  { csCategory     :: CategoryId
  , csGrossOutflow :: Cents        -- ^ Sum of negative Categorized lines (stored as <= 0, or abs >= 0)
  , csRefunds      :: Cents        -- ^ Sum of positive Categorized lines (returns/reimbursements >= 0)
  , csNetSpent     :: Cents        -- ^ Positive net expense = max 0 (negate (csGrossOutflow <> csRefunds)), plus signed net
  , csShareBp      :: BasisPoints  -- ^ Share of total positive net spending (0..10000 bp)
  } deriving stock (Eq, Show)

data GroupSpending = GroupSpending
  { gsGroup      :: CategoryGroupId
  , gsCategories :: [CategorySpending] -- ^ Sorted descending by net spend, omitting 0-activity rows
  , gsNetSpent   :: Cents
  , gsShareBp    :: BasisPoints
  } deriving stock (Eq, Show)
```

**Subtle Accounting Edge Cases Handled Explicitly:**
1. **Category Refunds (`S-2`):** If you bought €100 of clothing (`-10000` cents) and returned €40 (`+4000` cents) in the same month, your **Net Spending** on Clothing is **€60.00** (not €100 spent + €40 income!).
2. **Net-Positive Category Month (Refund Exceeds Spending):** If you bought €80 in October and returned it in November (`+€80.00` net activity in November with €0 new purchases), November's `CategoryActivity` is `+€80.00` (a net credit). Report `csNetActivity :: Cents` truthfully as `-€80.00` spent (or `+€80.00` net credit badge), while computing `csShareBp` strictly over categories with net outflow (`> €0` spent) so percentage bars always sum cleanly to ~`100.00%` (`10000 bp`, with largest-remainder rounding so shares sum to **exact `10000 bp`** when total spending `> 0`!).
3. **On-Budget Filter:** Just like `Domain.Budget.categoryActivity`, only `Categorized` transactions on `OnBudget` accounts count; `TransferLeg`s and `Tracking` accounts never appear in spending breakdowns.

**Visual presentation on `/reports`:**
- **Zero-JS Horizontal SVG Proportion Bar + Breakdown Table:**
  - Top stacked horizontal bar (`<svg viewBox="0 0 1000 32">`) showing each `CategoryGroup`'s share of monthly spending using a 6-color accessible palette in `/static/app.css`.
  - Expandable `<details open>` section per `CategoryGroup` showing group total, `%` share, and per-category rows (`Category | Gross Outflow | Refunds | Net Spent | % Share` with an inline `<svg width="120" height="10"><rect .../></svg>` proportion bar).

---

### 2.3 Report 3 — Monthly Cash-Flow & Savings Rate (`Inflows` vs. `Net Spending`)

Answers *"Did I live below my means each month?"* across the selected `[YearMonth]` window:

```haskell
data CashFlowMonth = CashFlowMonth
  { cfmMonth         :: YearMonth
  , cfmInflows       :: Cents              -- ^ Sum of on-budget Inflow transactions in month
  , cfmNetCategorized :: Cents             -- ^ Signed sum of all on-budget Categorized lines in month
  , cfmNetCashFlow   :: Cents              -- ^ cfmInflows <> cfmNetCategorized
  , cfmSavingsRateBp :: Maybe BasisPoints  -- ^ (cfmNetCashFlow / cfmInflows) when cfmInflows > 0
  } deriving stock (Eq, Show)
```

- **Opening-Balance Note:** Because Bucktracker models initial opening balances as `Inflow` transactions (`DECISIONS.md` §3), an account's very first opening-balance inflow can make Month 1's `cfmInflows` look unusually high. Provide an optional toggle `?excludeOpening=true` (or convention: exclude inflows whose `txPayee == "Opening Balance"`, documented in UI helper text) so users who want pure earned-income savings rates can filter opening balances cleanly without adding a new DB column!
- **Transfer to Tracking Note:** Today, `Db.Transaction.insertTransfer` forbids transfers between `OnBudget` and `Tracking` accounts (`DECISIONS.md` §3). Investing €500 from Checking into a Brokerage (`Tracking`) account is recorded as a `-€500` `Categorized` outflow on Checking (e.g., category `"Investments"`) plus a `+€500` `Inflow` on Brokerage (`Tracking`). Notice how cleanly both reports work together under this model:
  - On **Spending / Cash Flow** (On-Budget): €500 left liquid cash into the `"Investments"` envelope.
  - On **Net Worth** (On-Budget + Tracking): Checking `-€500` + Brokerage `+€500` = **`€0` net loss, full wealth preserved and tracked as investment growth!**

---

## 3. Hard Invariants for QuickCheck (`test/Domain/ReportSpec.hs`)

1. **Invariant R-1 (Net-Worth Ledger Identity):** For every `MultiMonthWorld` (including Tracking inflows, On-Budget inflows, splits, refunds, and same-status transfers) and every `YearMonth` $m$:
   $$\text{nwpNetWorth}(m) \equiv \sum_{a \in \text{accounts}} \text{accountBalance}(a, \{tx \mid \text{ym}(tx) \le m\})$$
   and $\text{nwpOnBudgetCash}(m) + \text{nwpTrackingAssets}(m) + \text{nwpTrackingLiabilities}(m) \equiv \text{nwpNetWorth}(m)$.
2. **Invariant R-2 (Asset/Debt Partition):** $\text{nwpTotalAssets}(m) \ge 0$, $\text{nwpTotalDebts}(m) \le 0$, and $\text{nwpTotalAssets}(m) + \text{nwpTotalDebts}(m) \equiv \text{nwpNetWorth}(m)$.
3. **Invariant R-3 (Transfer Neutrality):** Adding any valid `mkTransferPair` (either `OnBudget <-> OnBudget` or `Tracking <-> Tracking`) leaves `nwpNetWorth`, `cfmInflows`, `cfmNetCategorized`, and every `CategorySpending` **unchanged**.
4. **Invariant R-4 (Exact Basis-Point Conservation):** Whenever total positive category net spending $> 0$, the largest-remainder `BasisPoints` shares across all `CategoryGroup`s sum to **exact `10000` (`100.00%`)** with no floating-point rounding drift (`99.99%` / `100.01%` impossible!).
5. **Invariant R-5 (Cash-Flow Step Identity on On-Budget Cash):** Between any two consecutive months $m_{k-1}$ and $m_k$ (with only valid same-status transfers), $\text{nwpOnBudgetCash}(m_k) - \text{nwpOnBudgetCash}(m_{k-1}) \equiv \text{cfmNetCashFlow}(m_k)$.

---

## 4. Implementation Steps (Self-Contained Checklist)

- [ ] **Step R-1 — Pure `src/Domain/Report.hs` + `test/Domain/ReportSpec.hs`:** Implement `BasisPoints` (largest-remainder allocator), `buildNetWorthSeries`, `buildSpendingBreakdown`, `buildCashFlowSeries`, and all 5 QuickCheck invariants (`R-1`..`R-5`). Zero `IO`, zero `Double`/`Float`.
- [ ] **Step R-2 — Pure Integer SVG Helper (`src/Api/Svg.hs`) & `/static/app.css` Chart Styles:** Small Lucid `<svg>` element/attribute combinators (`svg_`, `rect_`, `line_`, `polyline_`, `g_`, `text_`, `title_`, `viewBox_`, etc. via `Lucid.Base.makeElement`/`makeAttribute` — **zero new Cabal dependencies!**) emitting presentation attributes + semantic CSS classes (`.chart-networth`, `.chart-bar-cash`, `.chart-bar-tracking`, `.chart-bar-debt`, `.chart-line`).
- [ ] **Step R-3 — Routes & Page (`src/Api/Reports.hs`, mounted at `/reports` + `Api.Html` nav link):**
  - `GET /reports?month=YYYY-MM&range=6|12|24` (default: current local month, trailing `12` months, capped at `60` months).
  - Single `withConn` + `withReadSnapshot` loading `accounts`, `groups`, `categories`, and `transactions` once.
  - Renders KPI summary cards, Net-Worth SVG chart + account snapshot table, Monthly Spending SVG stacked bar + grouped category breakdown, and Cash-Flow / Savings-Rate table.
- [ ] **Step R-4 — `test/Api/ReportsSpec.hs` & `ARCHITECTURE.md` Update:** End-to-end tests verifying On-Budget + Tracking net-worth math, refund netting, strict CSP compliance (zero `style="` attributes in response HTML!), and updated `"Where do I change X?"` entry.
