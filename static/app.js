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
      this.editing = false;
      // requestSubmit (not submit()) fires the real "submit" event, so
      // HTMX's own hx-post/hx-target/hx-swap on the form still
      // intercepts it exactly as a click on a submit button would.
      this.$refs.form.requestSubmit();
    },
  }));
});
