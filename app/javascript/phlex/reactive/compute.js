// The client-side compute (data-binding) registry — the "instant" half of the
// new/unpersisted-record UX.
//
// A record-backed reactive component round-trips every change to the server
// (the signed identity re-finds the record; the server re-renders). A NEW,
// unpersisted record has no such server truth to re-render against on every
// keystroke — the classic answer is a bespoke Stimulus controller doing the math
// in the browser (carlqvist's new_order_controller.js). This registry lets that
// math be a DECLARED part of the component instead: `reactive_compute :name,
// inputs:, outputs:` (Ruby) names a reducer registered here, and the generic
// reactive controller runs it on `input` — writing the outputs with NO round
// trip. When the component ALSO carries on(...) (a persisted record, or a draft
// you sync), the debounced POST reconciles from the authoritative server reply.
//
// The seam mirrors confirm.js: a settable registry with a lookup the controller
// calls. Register once at boot:
//
//   import { setComputeReducer } from "phlex/reactive/compute"
//   setComputeReducer("payment_split", ({ allowance, cash, leasing, total }) => ({
//     allowance, leasing, cash: total - allowance - leasing,
//   }))
//
// The reducer's signature is (values, meta):
//
//   values — a plain object of { inputName: value } over the declared inputs.
//            Untyped inputs (the array form) AND :number-typed inputs arrive as
//            Numbers (blank/NaN → 0); :string-typed inputs (the hash form,
//            issue #104) arrive as the RAW string. `reactive_compute :x, inputs:
//            { title: :string, qty: :number }` is what selects per-input types;
//            `inputs: %i[a b]` stays all-numeric (backward compatible).
//            A CHECKBOX arrives as its checked state, never its constant
//            .value (issue #262): 1/0 untyped or :number, "true"/"false" as a
//            :string, true/false as a :boolean. A radio group arrives as its
//            checked radio's value ("" / 0 when none is checked).
//   meta   — { changed }: the name (string) of the declared input the
//            triggering event edited, or null (a direct recompute() call, or a
//            target this root doesn't own / didn't declare as an input).
//
// OUTPUTS may be a form FIELD or a TEXT NODE (issue #104). An output whose name
// matches an owned control writes its .value (+ the change-guarded input
// dispatch below) — or, for a checkbox or a radio group, its CHECKED state
// (issue #262): a truthy result ticks the box ("", "0", "false", 0 and false
// untick it), and a radio group checks the radio carrying the result. Their
// value attributes are never rewritten, so what they submit is unchanged.
// An output with NO matching field writes textContent to every
// owned [data-reactive-text="<name>"] node (reactive_text(:name)) — XSS-safe by
// construction, change-guarded, NO input dispatch (a text node has no listener
// contract). A declared INPUT also mirrors into its own text node on every
// input via an always-run pass — so reactive_text(:title) is a live field
// preview with NO registered reducer at all.
//
// It returns a plain object of { outputName: value } — only the outputs it
// names are written, so it can leave the edited field (and its caret)
// untouched. A one-argument reducer keeps working unchanged (it just ignores
// meta). `changed` is what makes a MULTI-WAY / MUTUAL rebalance expressible as
// one reducer (issue #75) — branch on which field the user edited:
//
//   setComputeReducer("three_way_split", ({ field_a, field_b, field_c, total }, { changed }) => {
//     if (changed === "field_c") return { field_a: total - field_c - field_b }
//     return { field_c: total - field_a - field_b }
//   })
//
// Output writes are CHANGE-GUARDED: the controller writes a field and
// dispatches a bubbling `input` event on it ONLY when the new value differs
// from the field's current value (real browsers never fire `input` on a
// programmatic .value write, so the controller dispatches explicitly — that's
// what drives a chained summary repaint, matching the server's set_value +
// dispatch("input") contract). Returning the SAME value a field already holds
// is skipped entirely — no write, no event — which is why a reducer with
// overlapping inputs/outputs (like payment_split above) settles instead of
// re-entering itself forever.
//
// CONVERGENCE REQUIREMENT: because an output write dispatches a REAL input
// event (issue #76), recompute re-enters with changed = that OUTPUT field's
// name (when it's also a declared input). A branching reducer must therefore
// be convergent: the re-entrant pass must compute values EQUAL to what the
// first pass already wrote to the DOM, so the change guard settles the chain.
// The three_way_split above is: after `changed === "field_a"` writes field_c,
// the re-entrant `changed === "field_c"` pass derives field_a back to the
// value it already holds — no write, no event, settled in one bounce.

// THE RESERVED `$ops` OUTPUT (issue #226). Besides field/text outputs, a
// reducer may return the reserved key `$ops` holding a chain of client DOM
// ops — built with the `ops` builder below, or a raw [[name, args], ...]
// array. The controller consumes it as a PHASE 4 of the single-pass write set:
// the ops run AFTER the field writes, text sinks, and phase-3 input dispatches
// settle, through the SAME frozen CLIENT_OPS whitelist on_client uses (an
// unknown op warns + is skipped). `null`/`undefined`/absent = no effect.
//
// RISING-EDGE semantics, keyed on CONTENT: the chain runs only when it
// DIFFERS from the previous pass's chain (including from "absent"), and only
// on EVENT-DRIVEN passes. Returning the SAME chain again is settled — no
// re-fire (a 7th keystroke capped back to the same complete value can't
// re-submit), mirroring the change-guarded field writes. Returning a
// DIFFERENT chain fires again — a multi-box reducer advancing focus
// box-by-box emits a new focus target per digit, each a new intent. The
// connect/morph SEED pass (issue #199 — recompute with no event) ARMS the
// latch but never fires — a form re-rendered with an already-complete value
// (a validation-error morph, a browser restore) must not auto-fire; that is
// what breaks the submit → error re-render → re-seed → submit loop. A later
// pass returning no $ops re-arms. The canonical use — a one-time-code field
// that normalizes on input and commits when complete:
//
//   import { setComputeReducer, ops } from "phlex/reactive/compute"
//   setComputeReducer("otp", ({ code }) => {
//     const digits = code.replace(/\D/g, "").slice(0, 6)
//     return { code: digits, $ops: digits.length === 6 ? ops.submit() : null }
//   })
//
// `submit` commits the target's own form via requestSubmit() — the real submit
// event fires, so an on(:verify, event: "submit") interception (or a native/
// Turbo form) handles it exactly like a user submit. submit/focus are
// ACTOR-ONLY: usable here and in on_client/reply.js, refused in broadcasts.
// paste_into (issue #228) is actor-only too but DELIBERATELY absent from this
// builder: a reducer runs on every input event, and a clipboard read per
// keystroke (each changed chain fires) would spam permission prompts. Use it
// from on_client / reply.js / reactive_on_complete instead; a raw
// [["paste_into", …]] pair still interprets if you truly need it.

const reducers = new Map()

// Register (or replace) the reducer for `key`. `fn` is
// (values: Record<string, number>, meta: { changed: string | null })
//   => Record<string, unknown>.
export function setComputeReducer(key, fn) {
  reducers.set(key, fn)
}

// Look up a registered reducer; undefined when none — the controller then makes
// #recompute a no-op rather than throwing (a missing reducer must not break the
// page; it just means no client-side binding for that root).
export function computeReducer(key) {
  return reducers.get(key)
}

// Test seam: clear the registry so a reducer registered in one test can't leak.
export function __resetComputeRegistryForTest() {
  reducers.clear()
}

// --- The reducer-side op-chain builder (issue #226) --------------------------
//
// A thin, IMMUTABLE mirror of the Ruby Phlex::Reactive::JS builder (minus
// paste_into — see the actor-only note above): verbs carry
// the WIRE op names (snake_case) and append [name, args] pairs; every verb
// returns a NEW instance, so a chain held in a constant can never be mutated by
// later use. `.ops` exposes the raw [[name, args], ...] list the controller
// interprets (and toJSON serializes it, so a chain can also feed a hand-built
// ops attr). Targets: a CSS selector string, or omit for "@root" (the
// component's own root). No build-time attr validation here — the interpreter's
// allowlist (guardAttr) is the enforcement point; this builder only shapes the
// wire.
const ROOT_SENTINEL = "@root"

function targetArgs(to, { global, transition } = {}) {
  const args = { to: to ?? ROOT_SENTINEL }
  if (global) args.global = true
  if (transition) args.transition = normalizeTransition(transition)
  return args
}

// Named legs { during, from, to } → the [during, from, to] wire array (the
// issue #186 vocabulary). Loud at authoring time, like the Ruby builder.
// Frozen, like every nested payload — the chain's immutability contract must
// hold all the way down (the Ruby twin freezes its legs array too).
function normalizeTransition(transition) {
  const named =
    transition && typeof transition === "object" && !Array.isArray(transition) &&
    ["during", "from", "to"].every((k) => k in transition)
  if (!named) throw new Error("[phlex-reactive] ops transition takes named legs { during, from, to }")
  return Object.freeze([String(transition.during), String(transition.from), String(transition.to)])
}

class OpsChain {
  constructor(list = Object.freeze([])) {
    this.ops = list
    Object.freeze(this)
  }

  show(to, opts) {
    return this.#append("show", targetArgs(to, opts))
  }

  hide(to, opts) {
    return this.#append("hide", targetArgs(to, opts))
  }

  toggle(to, opts) {
    return this.#append("toggle", targetArgs(to, opts))
  }

  add_class(to, classes, opts) {
    return this.#append("add_class", classArgs(to, classes, opts))
  }

  remove_class(to, classes, opts) {
    return this.#append("remove_class", classArgs(to, classes, opts))
  }

  toggle_class(to, classes, opts) {
    return this.#append("toggle_class", classArgs(to, classes, opts))
  }

  set_attr(to, name, value, opts) {
    return this.#append("set_attr", { ...targetArgs(to, opts), name: String(name), value: String(value) })
  }

  remove_attr(to, name, opts) {
    return this.#append("remove_attr", { ...targetArgs(to, opts), name: String(name) })
  }

  toggle_attr(to, name, opts) {
    return this.#append("toggle_attr", { ...targetArgs(to, opts), name: String(name) })
  }

  focus(to, opts) {
    return this.#append("focus", targetArgs(to, opts))
  }

  focus_first(to, opts) {
    return this.#append("focus_first", targetArgs(to, opts))
  }

  text(to, value, opts) {
    return this.#append("text", { ...targetArgs(to, opts), value: String(value ?? "") })
  }

  dispatch(name, { to, detail, global } = {}) {
    const args = { name: String(name), to: to ?? ROOT_SENTINEL, detail: detail ?? {} }
    if (global) args.global = true
    return this.#append("dispatch", args)
  }

  submit(to, opts) {
    return this.#append("submit", targetArgs(to, opts))
  }

  toJSON() {
    return this.ops
  }

  #append(name, args) {
    return new OpsChain(Object.freeze([...this.ops, Object.freeze([name, Object.freeze(args)])]))
  }
}

// classes: one class string or an array of them (never whitespace-split — a
// classList token can't contain spaces, so splitting would only mask a bug).
// Loud on an empty/missing list, and frozen (the Ruby twin freezes its class
// list too) — a chain held in a constant must stay immutable all the way down.
function classArgs(to, classes, opts) {
  const list = classes == null ? [] : (Array.isArray(classes) ? classes : [classes]).map(String)
  if (list.length === 0) throw new Error("[phlex-reactive] a class op needs at least one class")
  return { ...targetArgs(to, opts), classes: Object.freeze(list) }
}

// The shared empty chain — start every reducer effect from here:
//   $ops: done ? ops.dispatch("code:complete").submit() : null
export const ops = new OpsChain()
