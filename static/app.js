// Bucktracker's own static JS — plain ES6, no build step, loaded via
// <script defer src="/static/app.js">. Alpine.js components are
// registered via `Alpine.data`, never inline `x-data="{ ... }"` object
// literals: the vendored build is the CSP build (DECISIONS.md §12),
// which can't evaluate arbitrary inline JS expressions — only simple
// property/method references in directives, and calls into
// pre-registered `Alpine.data` factories.
//
// Server remains the sole source of truth: every component here is
// ephemeral local UI state only (what's visible right now), never
// persisted data, and never does currency math on floating-point
// numbers — only passing already-formatted euro strings through to a
// real HTMX form submission, which Haskell parses and computes on
// independently (Api.Money, integer cents).

// Parses a euro string ("-25.50", "12,34", "12") into integer cents,
// total: returns null instead of throwing on anything it can't make
// sense of. Mirrors Api.Money.parseSignedEuros's shape (not its exact
// validation — this is only ever a *preview*; Haskell is still the
// one source of truth on submit, see the module comment above).
function parseEuroCents(text) {
  if (typeof text !== 'string') return null;
  const trimmed = text.trim();
  if (trimmed === '') return null;
  const negative = trimmed.startsWith('-');
  const unsigned = negative ? trimmed.slice(1) : trimmed;
  const normalized = unsigned.replace(',', '.');
  const parts = normalized.split('.');
  if (parts.length > 2 || parts[0] === '') return null;
  if (!/^\d+$/.test(parts[0])) return null;
  const whole = Number.parseInt(parts[0], 10);
  let fracText = parts.length === 2 ? parts[1] : '00';
  if (fracText.length === 1) fracText = fracText + '0';
  if (fracText.length !== 2 || !/^\d+$/.test(fracText)) return null;
  const frac = Number.parseInt(fracText, 10);
  const cents = whole * 100 + frac;
  return negative ? -cents : cents;
}

// The inverse of parseEuroCents, for displaying a live preview figure.
function formatEuroCents(cents) {
  const sign = cents < 0 ? '-' : '';
  const absValue = Math.abs(cents);
  const whole = Math.floor(absValue / 100);
  const frac = absValue % 100;
  return sign + whole + '.' + String(frac).padStart(2, '0');
}

document.addEventListener('alpine:init', () => {
  // Backs the inline click-to-edit "Assigned" cell on /budget
  // (Api.Budget.assignedCell). `initialDisplay` is the euro string
  // already rendered server-side (e.g. "50.00") — this component only
  // toggles between showing that text and showing an editable input
  // pre-filled with it; Haskell/Api.Money still owns parsing and
  // validating whatever the user actually submits.
  Alpine.data('inlineAssign', (initialDisplay) => ({
    editing: false,
    value: initialDisplay,
    displayValue: initialDisplay,

    get notEditing() {
      return !this.editing;
    },

    startEdit() {
      this.value = this.displayValue;
      this.editing = true;
      this.$nextTick(() => this.$refs.input.focus());
    },

    cancelEdit() {
      this.value = this.displayValue;
      this.editing = false;
    },

    submitEdit() {
      // Enter fires keydown.enter, which hides the input (editing =
      // false below) — in some browsers that itself then fires
      // "change" on the same input, calling submitEdit() a second
      // time. This guard makes a second call a no-op instead of a
      // duplicate POST.
      if (!this.editing) return;
      this.editing = false;
      // requestSubmit (not submit()) fires the real "submit" event, so
      // HTMX's own hx-post/hx-target/hx-swap on the form still
      // intercepts it exactly as a click on a submit button would.
      this.$refs.form.requestSubmit();
    },
  }));

  // Backs the spending form's split editor (Api.Transactions
  // .newSpendingForm). Deliberately no x-for/<template>: "Add"/
  // "Remove" just clone or remove a plain .split-line DOM node inside
  // $refs.lines — every line's inputs already share the same name
  // attributes (lineCategoryId/lineAmount) regardless of how many
  // lines exist, so there's no per-row indexing to keep in sync, and
  // this sidesteps needing more elaborate templating support from the
  // CSP build. Haskell/Domain.Transaction is still what actually
  // derives the transaction's total from whichever lines are
  // submitted (Invariant 3) — this is only a live preview.
  Alpine.data('splitEditor', () => ({
    receiptTotal: '',
    remainingLabel: '',

    addLine() {
      const lines = this.$refs.lines;
      const clone = lines.lastElementChild.cloneNode(true);
      const amountInput = clone.querySelector('input[name="lineAmount"]');
      if (amountInput) amountInput.value = '';
      lines.appendChild(clone);
      this.recalc();
    },

    removeLine(event) {
      const lines = this.$refs.lines;
      if (lines.children.length > 1) {
        event.target.closest('.split-line').remove();
      }
      this.recalc();
    },

    recalc() {
      const total = parseEuroCents(this.receiptTotal);
      if (total === null) {
        this.remainingLabel = '';
        return;
      }
      const amountInputs = this.$refs.lines.querySelectorAll('input[name="lineAmount"]');
      let sum = 0;
      amountInputs.forEach((input) => {
        sum += parseEuroCents(input.value) ?? 0;
      });
      const remaining = total - sum;
      const doneMarker = remaining === 0 ? ' ✓' : '';
      this.remainingLabel = 'Unallocated: ' + formatEuroCents(remaining) + doneMarker;
    },
  }));

  // Backs the reconcile form on /accounts (Api.Accounts.reconcileForm).
  // clearedCents comes from the element's own data-cleared-cents
  // attribute (the server-computed Domain.Budget.clearedBalance, in
  // integer cents) — this component only ever previews
  // Cleared - Statement = Difference as the user types; whether they
  // actually match, and whether to write anything, is still decided
  // server-side in Api.Accounts.reconcileAccountHandler.
  Alpine.data('reconcileCalc', () => ({
    statementBalance: '',
    differenceLabel: '',

    init() {
      this.clearedCents = Number.parseInt(this.$el.dataset.clearedCents, 10) || 0;
    },

    recalc() {
      const statementCents = parseEuroCents(this.statementBalance);
      if (statementCents === null) {
        this.differenceLabel = '';
        return;
      }
      const difference = this.clearedCents - statementCents;
      const matchMarker = difference === 0 ? ' ✓' : '';
      this.differenceLabel =
        'Cleared ' + formatEuroCents(this.clearedCents) +
        ' - Statement ' + formatEuroCents(statementCents) +
        ' = Difference ' + formatEuroCents(difference) + matchMarker;
    },
  }));
});

// Global keyboard shortcuts for the <details> entry drawers on
// /transactions (Api.Transactions.newInflowForm/newSpendingForm/
// newTransferForm): n/i/t open one, Escape closes whichever is open.
// Plain DOM, not an Alpine component — this has no per-element state
// of its own, just document-level key handling, so it runs
// independently of Alpine's lifecycle entirely.
document.addEventListener('keydown', (event) => {
  if (event.key === 'Escape') {
    document.querySelectorAll('details[open]').forEach((details) => {
      details.open = false;
    });
    return;
  }

  const target = event.target;
  const isTyping =
    target && (target.tagName === 'INPUT' || target.tagName === 'TEXTAREA' || target.tagName === 'SELECT');
  if (isTyping || event.metaKey || event.ctrlKey || event.altKey) return;

  const detailsIdByKey = {
    n: 'new-expense-details',
    i: 'new-inflow-details',
    t: 'new-transfer-details',
  };
  const detailsId = detailsIdByKey[event.key];
  if (!detailsId) return;

  const details = document.getElementById(detailsId);
  if (!details) return;
  details.open = true;
  const firstField = details.querySelector('input, select');
  if (firstField) firstField.focus();
});
