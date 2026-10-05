// phlex/reactive/features/compute — client-side computes (data binding,
// issues #104, #159, #183, #199, #262): `recompute`, the connect-time seed,
// text mirrors and the reducer's $ops. One of the feature modules the opt-in
// client imports on demand (issue #275); in the default client it is part of
// the one file.
//
// The reducer registry is the compute seam (phlex/reactive/compute), imported
// here by its bare name — so the runtime no longer imports it, and a page
// with no compute binding never resolves it. The seed writes output fields a
// request collects, so with the opt-in client the feature `gates`: a root's
// requests wait for it. While the module is on its way, the opt-in entry
// records that the user edited a field (`pending.edited`), and connect() runs
// ONE recompute then: the reducer reads the inputs as the user left them, so
// nothing they typed is overwritten, and a `recompute` the window dispatched
// has run exactly once when it is over.
//
// This module never imports the runtime: it reaches a controller through the
// `core` handle.
import { computeReducer } from "phlex/reactive/compute"

// controller -> its context: the root, the core handle, and what used to be
// the controller's own fields for this feature.
const contexts = new WeakMap()

function ctx(controller, core) {
  let c = contexts.get(controller)
  if (!c) {
    c = {
      controller,
      root: controller.element,
      core,
      // Issue #183: the `input` events recompute dispatched for its OWN output
      // writes, so re-entering from one skips the reducer (and ONLY one of ours).
      computeSelfDispatched: new WeakSet(),
      // The reducer's last $ops chain (issue #226), the rising-edge latch.
      computeOpsSignature: null,
    }
    contexts.set(controller, c)
  }
  return c
}

export function connect(controller, core, _morphed, pending) {
  const c = ctx(controller, core)
  // Connect-time compute seed (issue #199) — ONLY when the root carries a
  // reactive_compute binding that opts in (data-reactive-compute-seed). A
  // freshly-rendered compute root (a first paint, or a server validation-error
  // re-render that replaced the body) computed NOTHING until the first user
  // `input`; apps worked around it by dispatching a synthetic seed `input` on
  // connect, but the compute root is a distinct Stimulus controller that may
  // connect a frame later, so the seed raced its own wiring. Running ONE
  // recompute() HERE — after Stimulus has fully connected the controller and
  // wired the input->recompute delegation — runs the whole single-pass write
  // set (issue #183) synchronously, so every declared output, text sink, and
  // cross-root mirror paints from one reducer result. It is client-only
  // (recompute never enqueues a round trip) and idempotent (change-guarded
  // writes make a re-seed a no-op). A plain replace re-connects and re-seeds;
  // an in-place morph keeps the element CONNECTED and fires no Stimulus
  // lifecycle, so ALSO re-seed on turbo:morph-element. No event is passed, so
  // meta.changed is null — the correct "no field edited yet" seed semantics; a
  // convergent reducer's default branch computes the full settled set (see
  // compute.js CONVERGENCE REQUIREMENT).
  const seeds = computeSeedEnabled(c)
  if (seeds) {
    c.boundSeedCompute = () => recompute(c)
    c.root.addEventListener?.("turbo:morph-element", c.boundSeedCompute)
  }
  // The one pass a root that waited for this module owes: its seed, or the
  // recompute an edit in the window asked for.
  if (seeds || pending?.edited) recompute(c)
}

export function disconnect(controller) {
  const c = contexts.get(controller)
  if (!c) return
  contexts.delete(controller)
  if (c.boundSeedCompute) c.root.removeEventListener?.("turbo:morph-element", c.boundSeedCompute)
}

// Re-run the seed (for a feature that changed field values after connect:
// the draft restore).
export function seed(controller) {
  contexts.get(controller)?.boundSeedCompute?.()
}

// The Stimulus action (input->reactive#recompute); the controller's method of
// the same name hands the event here.
function publicRecompute(controller, core, event) {
  return recompute(ctx(controller, core), event)
}
export { publicRecompute as recompute }

// The control for a name nothing owned resolves to.
const COMPUTE_NO_CONTROL = Object.freeze({ el: null, kind: "" })

// A cross-root mirror target must be a single ID selector (issue #159) — "#" +
// a CSS identifier, nothing else. The client half of the two-sided default-deny
// (reactive_compute's `mirror:` validates the SAME shape loudly at declare
// time): a hand-built mirror attr must not widen a declared text mirror into a
// page-wide selector write. A refused selector warns + skips (its siblings
// still apply), matching the attr-allowlist posture.
const MIRROR_ID_SELECTOR = /^#[A-Za-z_][\w-]*$/

// The TEXT reading of a compute control (issue #262) — what a :string input
// hands the reducer and what the identity/cross-root mirrors paint. A checkbox
// reads its CHECKED STATE ("true"/"false", the strings reactive_show compares
// against): its .value is a constant — "1", "on", whatever the markup says —
// so reading it told the reducer nothing. A radio reads its value only while
// checked ("" otherwise; the resolver hands over the checked radio of a group).
// Anything else reads .value, as it always has.
//
// Every compute helper takes a CONTROL — the { el, kind } record #recompute's
// resolver builds, kind being "checkbox", "radio" or "" — and never re-reads
// el.type: the resolver reads it ONCE per name. Re-reading it in each helper
// cost the 30-input calculator bench ~60% (16.8 → 27 µs/iter, measured).
function computeText({ el, kind }) {
  if (!el) return ""
  if (kind === "checkbox") return el.checked ? "true" : "false"
  if (kind === "radio") return el.checked ? (el.value ?? "") : ""
  return el.value ?? ""
}

// Whether a value counts as "on" — for a :boolean input read off a control that
// is not a checkbox, and for an output written INTO a checkbox. A boolean is
// itself; otherwise "", "0" and "false" are off (what a hidden flag field or a
// reducer returning 0 means) and anything else is on.
function computeTruthy(value) {
  if (typeof value === "boolean") return value
  if (value == null) return false
  const text = String(value)
  return text !== "" && text !== "0" && text !== "false"
}

// One declared input's value for the reducer, coerced by its declared type
// (issue #104; checked-state controls issue #262):
//
//   "string"  → the text reading, raw (blank/absent → "")
//   "boolean" → a checkbox's checked state; any other control by computeTruthy
//   "number"  → a checkbox is 1/0; anything else through Number (blank/NaN → 0,
//               the nanToZero the hand-written calculators use)
//
// A checkbox is 1/0 and never Number(its value): a box is a yes/no, and a
// reducer that wants an amount writes `gift ? 25 : 0`.
function computeValue(control, type) {
  if (type === "string") return computeText(control)
  const box = control.kind === "checkbox"
  if (type === "boolean") return box ? Boolean(control.el.checked) : computeTruthy(computeText(control))
  if (box) return control.el.checked ? 1 : 0
  const n = Number(computeText(control))
  return Number.isFinite(n) ? n : 0
}

// Write one reducer output into the control its name resolved to (issue #262),
// change-guarded. Returns the element to announce with an `input` event, or
// null when nothing changed. A checkbox takes the result as its checked state
// and a radio group checks the radio carrying it — neither ever has its value
// attribute rewritten, which would change what the control SUBMITS. Anything
// else takes the result as its .value (issue #76).
function computeWrite(root, owns, { el, kind }, domName, value) {
  if (kind === "checkbox") {
    const checked = computeTruthy(value)
    if (Boolean(el.checked) === checked) return null
    el.checked = checked
    return el
  }
  if (kind === "radio") return computeCheckRadio(root, owns, domName, String(value))
  if (String(value) === el.value) return null
  el.value = value
  return el
}

// Check the owned radio of a group whose value is `wanted`, unchecking the
// rest — the same per-radio rule a restored draft applies. A value no radio
// carries clears the group. Returns the radio that GAINED the check, or, for a
// cleared group, the one that lost it; null when the selection already matched.
function computeCheckRadio(root, owns, domName, wanted) {
  let announced = null
  for (const el of root.querySelectorAll(`[name="${domName}"]`)) {
    if (el.type !== "radio" || !owns(el)) continue
    const checked = el.value === wanted
    if (Boolean(el.checked) === checked) continue
    el.checked = checked
    if (checked) announced = el
    else announced ??= el
  }
  return announced
}

// Normalize a reducer's reserved $ops output (issue #226): the compute `ops`
// builder (its .ops list), a raw [[name, args], ...] array, or null/undefined
// (no effect this pass). An EMPTY list is the same as null — "nothing to run"
// must not latch the rising edge. Anything else warns + is dropped
// (default-deny, like every other malformed op source). Reducers are trusted
// app code, but their ops still run through the frozen CLIENT_OPS whitelist.
function computeOpsList(raw) {
  if (raw == null) return null
  const list = Array.isArray(raw) ? raw : raw.ops
  if (Array.isArray(list)) return list.length > 0 ? list : null
  console.warn("[phlex-reactive] $ops must be an ops chain or a [[op, args], ...] list — skipped")
  return null
}

function guardMirrorSelector(selector) {
  if (typeof selector === "string" && MIRROR_ID_SELECTOR.test(selector)) return true
  console.warn(`[phlex-reactive] refused cross-root mirror target ${JSON.stringify(selector)} — skipped`)
  return false
}

// Apply a reducer-emitted $ops chain (issue #226) on its RISING EDGE, keyed
// on CONTENT: fire only when THIS pass's chain differs from the LAST pass's
// (including from "absent"), and only on an event-driven pass. An unchanged
// chain never re-fires — "still complete, same submit" is settled, exactly
// like the change-guarded field writes. A pass with no $ops re-arms; a pass
// whose chain CHANGED fires again (per-keystroke focus advance across OTP
// boxes is a different focus target each time — a deliberately new intent).
// Ops run through the shared CLIENT_OPS interpreter with runOps's
// root-scoped target resolution; a missing to: defaults to "@root"
// (hand-written reducer ergonomics).
function applyComputeOps(c, list, eventDriven) {
  const signature = list === null ? null : JSON.stringify(list)
  const fire = signature !== null && signature !== c.computeOpsSignature && eventDriven
  c.computeOpsSignature = signature
  if (!fire) return
  c.core.applyOps(list, "@root")
}

// Parse a JSON string list from a root data attr; [] on absence/parse error so
// a malformed binding degrades to "no fields" rather than throwing on input.
function parseComputeList(c, attr) {
  const raw = c.root.getAttribute(attr)
  if (!raw) return []
  try {
    const list = JSON.parse(raw)
    return Array.isArray(list) ? list : []
  } catch {
    return []
  }
}

// Parse the inputs param into [name, type] pairs (issue #104). The wire is a
// JSON ARRAY of names (array form → every input typed "number", the shipped
// numeric coercion) OR a JSON OBJECT of name→type (hash form → ":string" read
// raw, ":number" coerced). Malformed/absent degrades to [] — a bad binding
// must never throw on input.
function parseComputeInputs(c) {
  const raw = c.root.getAttribute("data-reactive-compute-inputs-param")
  if (!raw) return []
  try {
    const parsed = JSON.parse(raw)
    if (Array.isArray(parsed)) return parsed.map((name) => [name, "number"])
    if (parsed && typeof parsed === "object") return Object.entries(parsed)
    return []
  } catch {
    return []
  }
}

// The declared compute input the event just edited — the reducer's
// meta.changed (issue #75). The triggering field counts only when it is a
// named form control OWNED by this root (not a nested reactive root's, issue
// #15) AND its name is among the declared compute inputs; anything else
// (a direct call, an unowned/undeclared target) yields null.
//
// Scope-aware (issue #184): under data-reactive-scope, the edited field's DOM
// name is scoped (order[allowance]) while the declared inputs are BARE
// (allowance). Strip the scope prefix off the DOM name before comparing, and
// return the BARE name — so a reducer branching on `changed` sees the same
// names it declared, scoped or not.
function changedComputeField(c, event, inputs, scope) {
  const target = event?.target
  if (!target?.name || typeof target.closest !== "function") return null
  const bare = unscopeName(c, target.name, scope)
  if (!inputs.includes(bare)) return null
  return c.core.owns(target) ? bare : null
}

// Strip a leading `scope[…]` wrapper off a DOM field name, returning the bare
// inner name; a name that isn't wrapped in this scope passes through unchanged.
function unscopeName(c, name, scope) {
  if (!scope) return name
  const prefix = `${scope}[`
  return name.startsWith(prefix) && name.endsWith("]") ? name.slice(prefix.length, -1) : name
}

// Write `value` into every owned [data-reactive-text="<name>"] node via
// textContent (issue #104) — XSS-safe by construction (never innerHTML). Drives
// both the identity mirror (an input's raw value) and a text-node output (a
// reducer result with no matching field). Change-guarded (skip an unchanged
// node) and NO input dispatch — a text node has no listener contract. String()
// so a numeric result renders like the DOM would.
function mirrorText(c, name, value) {
  const text = String(value)
  for (const node of ownedTextNodes(c, name)) {
    if (node.textContent === text) continue
    node.textContent = text
  }
}

// Every [data-reactive-text="<name>"] mirror OWNED by this root (skips nested
// reactive roots, issue #15). Empty when none — reactive_text is optional.
function ownedTextNodes(c, name) {
  const nodes = c.root.querySelectorAll(`[data-reactive-text="${name}"]`)
  return Array.from(nodes).filter((el) => c.core.owns(el))
}

// Cross-root text mirrors (issue #159): paint every DECLARED mirror name into
// its allowlisted document-wide id targets via textContent — the opt-in escape
// from root isolation (issue #15) for a recap OUTSIDE the computing root. The
// value is the reducer's result when it produced one, else the owned field's
// CURRENT value (an input identity mirror / a just-written output) — one
// declaration covers all three shapes. A name with NO value this pass is
// SKIPPED (a mirror never blanks a recap the reducer didn't feed). textContent
// only (never innerHTML), change-guarded, and NO input dispatch — same
// contract as #mirrorText. With no mirror declared this is one getAttribute
// and out — the shipped compute path never touches the document.
function applyComputeMirrors(c, result, ownedControl) {
  const mirror = parseComputeMirror(c)
  for (const [name, selectors] of Object.entries(mirror)) {
    const control = name in result ? null : ownedControl(name)
    const value = name in result ? result[name] : control.el ? computeText(control) : undefined
    if (value === undefined || value === null) continue
    const text = String(value)
    for (const sel of Array.isArray(selectors) ? selectors : [selectors]) {
      if (!guardMirrorSelector(sel)) continue
      for (const node of document.querySelectorAll(sel)) {
        if (node.textContent === text) continue
        node.textContent = text
      }
    }
  }
}

// The declared cross-root mirror map (issue #159): a JSON object of
// { name: [id selectors] } from data-reactive-compute-mirror-param (emitted by
// reactive_compute's `mirror:`). Absent/malformed degrades to {} — a bad
// binding must never throw on input.
function parseComputeMirror(c) {
  const raw = c.root.getAttribute("data-reactive-compute-mirror-param")
  if (!raw) return {}
  try {
    const parsed = JSON.parse(raw)
    return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : {}
  } catch {
    return {}
  }
}

// Whether this root opts into the connect-time compute seed (issue #199).
// reactive_compute's root binding emits data-reactive-compute-seed="true"; a
// root without a compute binding (or with the seed opted out) pays one
// attribute read and never seeds. A quick read, evaluated once per connect.
function computeSeedEnabled(c) {
  return c.root.getAttribute?.("data-reactive-compute-seed") === "true"
}

// Client-side compute (data binding). Wired by reactive_compute: an `input`
// trigger (input->reactive#recompute) runs a REGISTERED JS reducer over the
// named input fields and writes the named output fields WITH NO ROUND TRIP —
// the "instant" half of the new/unpersisted-record UX. If the field ALSO
// carries on(...) (a persisted record, or a synced draft), that debounced POST
// still fires and the server reply reconciles; recompute just paints first.
//
// Reads inputs/outputs/reducer from the root's data-reactive-compute-* attrs
// (set once by reactive_compute_attrs). A missing/unregistered reducer is a
// no-op — a page must never break because a binding wasn't wired up.
//
// The reducer gets a second argument, meta = { changed } (issue #75): the
// name of the declared input the triggering event edited, or null for a
// direct call / an unowned or undeclared target. A multi-way rebalance
// branches on it (edit c → derive a; else → derive c). Note that a #76
// output write dispatches a real input event, so recompute RE-ENTERS with
// changed = that output's name — the reducer must be convergent (see
// compute.js) so the change guard settles the chain.
function recompute(c, event) {
  // Issue #183 — single-pass write set: an `input` event this method dispatched
  // for its OWN output writes is self-marked. Re-running the reducer on it would
  // re-enter from a partially-written DOM (the old mid-loop-dispatch corruption
  // class). Skip the reducer for our own event — but ONLY ours: the marker lives
  // in a per-instance WeakSet, so a genuinely different root's compute event (or
  // a real user edit) is never swallowed. The event still bubbled and fired every
  // OTHER listener (dirty tracking, show bindings, sibling roots) before reaching
  // here; we simply don't recompute a second time from our own write.
  if (event && c.computeSelfDispatched.has(event)) return

  // Inputs may be a JSON ARRAY of names (array form — every input coerced
  // through Number, the shipped behavior) or a JSON OBJECT of name→type (hash
  // form, issue #104 — :number coerced, :string read raw). #parseComputeInputs
  // returns [name, type] pairs either way (array form defaults type "number").
  const inputPairs = parseComputeInputs(c)
  const inputs = inputPairs.map(([name]) => name)

  // Resolve every declared input AND output through ONE per-call resolver whose
  // ownership probe is computed ONCE (issue #117), replacing the per-name
  // closest() walk #ownedField did on every read — a 30-field calculator paid
  // ~60 closest() sweeps per keystroke. #ownershipFilter returns a constant-true
  // predicate in the common no-nested-root case (skipping closest() entirely)
  // and the exact #ownsField check when a nested reactive root is present
  // (issue #15 scoping, byte-identical to before). Resolution is memoized in a
  // per-CALL Map, so a name read as an input AND written as an output
  // resolves to the SAME element and is queried once.
  //
  // Which element a name resolves to (issue #262, mirroring #showFieldValue): a
  // CHECKBOX wins over the hidden companion Rails renders before it; a radio
  // group resolves to its CHECKED radio (any radio of the group when none is);
  // anything else is first-wins. Resolving first-wins across the board handed
  // the reducer the companion's constant "0" and the first radio's value.
  //
  // Why per-name `[name="X"]` queries and not one bare `[name]` sweep: a single
  // sweep is the natural "one walk", but the resolver must issue the SAME
  // per-name query shape the field walk always has (the issue-#15 unit fakes
  // answer only `[name="X"]`). It is O(distinct declared names) queries, not the
  // old O(inputs + outputs) — the ownership decision is hoisted out of the loop.
  // The memo is per-CALL only: an output write dispatches `input` (issue #76),
  // re-entering recompute, which correctly rebuilds a fresh map (a morph may
  // have replaced the nodes) — it is NEVER stored on the instance.
  // Scope (issue #183, mirroring #showFieldValue): a bare compute name `cash`
  // under `data-reactive-scope="order"` resolves as `[name="order[cash]"]`. A
  // name already carrying a bracket (a raw wire name the author passed) is used
  // verbatim — so bracketed literals pass through unscoped.
  const scope = c.root.getAttribute?.("data-reactive-scope") || null
  const scoped = (name) => (scope && !name.includes("[") ? `${scope}[${name}]` : name)

  const owns = c.core.ownership()
  const byName = new Map()
  const ownedControl = (name) => {
    const known = byName.get(name)
    if (known) return known
    let radio = null
    let first = null
    let control = null
    for (const el of c.root.querySelectorAll(`[name="${scoped(name)}"]`)) {
      if (!owns(el)) continue
      const kind = el.type // read ONCE per element — see computeText
      if (kind === "checkbox" || (kind === "radio" && el.checked)) {
        control = { el, kind }
        break
      }
      if (kind === "radio") radio ??= el
      else first ??= el
    }
    if (!control) {
      if (radio) control = { el: radio, kind: "radio" }
      else control = first ? { el: first, kind: "" } : COMPUTE_NO_CONTROL
    }
    byName.set(name, control)
    return control
  }

  // Identity-mirror pass (issue #104), ALWAYS run — even with NO registered
  // reducer, so reactive_text(:title) mirrors a field into its text node with
  // zero reducer wiring. Each declared input's RAW text reading (computeText —
  // a checkbox paints "true"/"false", issue #262) is written to its owned
  // [data-reactive-text="<name>"] node(s). It runs BEFORE the reducer
  // early-return below so a reducer-less binding still mirrors.
  for (const name of inputs) mirrorText(c, name, computeText(ownedControl(name)))

  const key = c.root.getAttribute("data-reactive-compute-reducer-param")
  const reduce = key ? computeReducer(key) : null
  if (!reduce) {
    // No reducer registered: the identity pass above still ran, so declared
    // cross-root mirrors of the INPUT names still paint (issue #159) — a
    // reducer-less binding mirrors, exactly like the owned-text-node case.
    applyComputeMirrors(c, {}, ownedControl)
    return
  }

  const outputs = parseComputeList(c, "data-reactive-compute-outputs-param")

  // Coerce each input per its declared type (computeValue): "string" raw,
  // "boolean" a real boolean, else ("number", the array-form default) the
  // numeric coercion. A checkbox contributes its CHECKED STATE under every
  // type (issue #262). Reads from the memoized resolver — no re-query.
  const values = {}
  for (const [name, type] of inputPairs) values[name] = computeValue(ownedControl(name), type)

  // meta.changed stays on #changedComputeField (its own #ownsField check over
  // the raw event target) — NOT this resolver. The issue-#15 nested-rejection
  // test depends on that path being unchanged. ONE run, from the ONE pre-write
  // snapshot above (issue #183): its result drives the whole single-pass write.
  const result = reduce(values, { changed: changedComputeField(c, event, inputs, scope) }) || {}

  // The reserved $ops output (issue #226) is CONSUMED here — normalized once,
  // then excluded from every write phase below (it is an op chain, never a
  // field value, text sink, or mirror), and applied as phase 4.
  const reducerOps = computeOpsList(result.$ops)

  // Issue #183 — SINGLE-PASS WRITE SET. Ordered phases, so declared output
  // order stops being semantics and a wrong order can no longer corrupt values:
  //
  //   1. BATCH the field writes from the ONE result. Each output name in the
  //      allowlist (outputs:) whose owned field's value actually changes is
  //      written now (change-guarded) and remembered — but NO `input` event is
  //      dispatched yet, so nothing re-enters mid-batch. A checkbox or radio
  //      output is written as its CHECKED state (computeWrite, issue #262).
  //   2. PAINT the sinks from the SETTLED values: any owned reactive_text node by
  //      presence (issue #183 change #4 — a text node no longer needs its name in
  //      outputs:), then the cross-root mirror: ids (issue #159).
  //   3. DISPATCH a self-marked `input` on each changed field. The marker (a
  //      per-instance WeakSet) makes recompute skip re-running the reducer for our
  //      own write, while the event still fires every OTHER listener (chained
  //      repaint, dirty tracking, show bindings, sibling roots).
  //   4. RUN the reducer's $ops chain (issue #226) — rising-edge, event-gated —
  //      so its ops (dispatch a completion event, submit the form) always see
  //      the fully settled DOM and every chained listener has already run.
  const changedFields = []
  for (const name of outputs) {
    if (name === "$ops" || !(name in result)) continue
    const control = ownedControl(name)
    if (!control.el) continue // a non-field output paints as a text sink in phase 2
    const written = computeWrite(c.root, owns, control, scoped(name), result[name])
    if (written) changedFields.push(written) // null = change-guard, unchanged
  }

  // Phase 2 — text sinks declare themselves (issue #183 change #4): every result
  // key paints into any owned [data-reactive-text="<name>"] node by PRESENCE,
  // regardless of outputs: membership. Runs from settled field values. A null/
  // undefined result value is SKIPPED (never stringified to "null"/"undefined") —
  // the same "no value this pass, don't paint" filter #applyComputeMirrors uses.
  for (const name of Object.keys(result)) {
    if (name === "$ops") continue
    const value = result[name]
    if (value === undefined || value === null) continue
    mirrorText(c, name, value)
  }

  // Cross-root text mirrors (issue #159) — AFTER the batch + text sinks, so a
  // mirror keyed on a just-written output paints the settled value.
  applyComputeMirrors(c, result, ownedControl)

  // Phase 3 — dispatch the deferred `input` events (issue #183). Real browsers
  // do NOT fire `input` on a programmatic .value write (issue #76), so we do it
  // ourselves, matching the server's set_value + dispatch("input") contract.
  // Each event is SELF-MARKED so our own re-entry skips the reducer (guard at the
  // top of recompute) — but the event still bubbles and fires every other
  // listener. Dispatched AFTER all writes + paints, so a chained listener reads
  // SETTLED values, never a half-written DOM.
  for (const field of changedFields) {
    const inputEvent = new Event("input", { bubbles: true })
    c.computeSelfDispatched.add(inputEvent)
    field.dispatchEvent(inputEvent)
  }

  // Phase 4 — the reducer's $ops chain (issue #226), after everything settled.
  // Event-gated: a seed/direct recompute() pass (no event) arms the latch but
  // never fires, so a restored/re-rendered complete value can't auto-fire.
  applyComputeOps(c, reducerOps, Boolean(event))
}
