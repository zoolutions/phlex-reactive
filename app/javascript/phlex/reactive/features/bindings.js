// phlex/reactive/features/bindings — what a form root wires at connect and
// re-syncs after a morph, all of it client-only and all of it reading the
// root's own controls: show bindings and cross-root show targets (issues
// #161, #164, #176, #180, #209), completion bindings (#226), option filtering
// (#163), the tag-chip input (#203) and draft nested-attribute rows with their
// JSON mode (#208). One of the feature modules the opt-in client imports on
// demand (issue #275); in the default client it is part of the one file.
//
// Grouped because they share a shape — a marker check at connect, one
// delegated listener pair on the root, a seed, the same pass again on
// turbo:morph-element — and a page: a form with a show binding is the form
// that filters options and adds rows. The seeds here write visible state
// (and the JSON mode writes a hidden field a request collects), so with the
// opt-in client the feature `gates`: a root's requests wait for it.
//
// The conditional confirm (issue #179) lives here too: its condition is the
// same DNF fold a show binding uses, and its `predicate:` form reads the
// confirm_predicate seam — imported here by its bare name, so the runtime no
// longer imports it. A plain string confirm: never comes here; a conditional
// one on the opt-in client waits for this module before its dialog (a root
// with one preloads it).
//
// This module never imports the runtime: it reaches a controller through the
// `core` handle.
import { confirmPredicate } from "phlex/reactive/confirm_predicate"

// controller -> its context: the root, the core handle, and what used to be
// the controller's own fields for these features.
const contexts = new WeakMap()

function ctx(controller, core) {
  let c = contexts.get(controller)
  if (!c) {
    c = {
      controller,
      root: controller.element,
      core,
      tagsWarnedTemplate: false,
      nestedIndex: 0,
      nestedWarned: false,
      onCompleteRaw: undefined,
      onCompleteParsed: undefined,
      onCompleteStates: undefined,
    }
    contexts.set(controller, c)
  }
  return c
}

export function connect(controller, core) {
  const c = ctx(controller, core)
  const root = c.root

  // Show bindings (issue #161) — ONLY when this root owns one, so a component
  // without any pays a single probe (the dirty-tracking gate precedent). ONE
  // delegated listener pair on the root (input + change bubble from every
  // owned field — no per-field wiring, and a reactive_compute output write
  // dispatches a real input event, so computed values drive visibility too).
  // The connect sync seeds the initial state — a plain replace re-connects —
  // and turbo:morph-element re-syncs after an in-place morph (which keeps the
  // element connected, fires no Stimulus lifecycle, and may preserve a
  // user-edited field value the server's hidden attrs don't reflect).
  if (showSyncEnabled(c)) {
    // A select-all header's edit flips its group first (issue #319) — on
    // `input`, which a click fires BEFORE `change`, or the pass below would
    // reset the header to its group's state first (the flip is idempotent, so
    // the `change` that follows flips nothing). The change events it
    // dispatches re-enter here and are skipped while it flips, so the pass
    // after the loop runs once, not once per box.
    c.boundSyncShow = (event) => {
      if (c.flipping) return
      // Only a user edit pushes the header onto its group; a morph (whose
      // turbo:morph-element bubbles from the header too) derives it instead.
      if (event?.type === "input" || event?.type === "change") flipGroup(c, event.target)
      // Whether this root has group bindings is read at connect and again on
      // a morph (which may add one, and so need the observer) — never per
      // keystroke.
      else {
        c.groups = hasGroups(c)
        observeGroups(c)
      }
      syncShow(c)
    }
    root.addEventListener?.("input", c.boundSyncShow)
    root.addEventListener?.("change", c.boundSyncShow)
    root.addEventListener?.("turbo:morph-element", c.boundSyncShow)
    c.boundSyncShow()
  }

  // Completion bindings (issue #226) — ONLY when the root declares
  // data-reactive-on-complete (the show/filter gate precedent). ONE
  // delegated input+change listener evaluates every binding's DNF over the
  // owned fields and runs its ops on the RISING EDGE — the event-driven
  // flip to true. The connect pass ARMS without firing (a fresh render with
  // already-satisfied conditions must never self-fire — the $ops seed
  // precedent), and turbo:morph-element re-arms the same way after an
  // in-place morph. Listeners added HERE run after the Stimulus-wired
  // recompute delegation for the same event, so the evaluation reads
  // compute-NORMALIZED values (and a compute output write dispatches a real
  // input event that re-evaluates anyway).
  if (onCompleteEnabled(c)) {
    c.boundSyncOnComplete = (event) => syncOnComplete(c, event)
    c.boundArmOnComplete = () => {
      syncOnComplete(c, null)
      observeGroups(c)
    }
    root.addEventListener?.("input", c.boundSyncOnComplete)
    root.addEventListener?.("change", c.boundSyncOnComplete)
    root.addEventListener?.("turbo:morph-element", c.boundArmOnComplete)
    c.boundArmOnComplete()
  }

  // Option filtering (issue #163) — ONLY when the root declares the binding
  // (reactive_filter emits both attrs together), so a component without one
  // pays two attribute reads. ONE delegated input listener on the root — the
  // handler re-filters only for events from the NAMED input, so keystrokes in
  // unrelated fields on a wide form never pay a filter pass. The connect sync
  // seeds from the input's current value (a plain replace re-connects; back
  // navigation may restore typed text), and turbo:morph-element re-applies
  // after an in-place morph (which keeps the element connected, fires no
  // Stimulus lifecycle, and may preserve the user's typed query while the
  // server re-rendered every option visible).
  if (filterEnabled(c)) {
    c.boundSyncFilter = (event) => {
      if (event?.type === "input" && !filterInputEvent(c, event)) return
      syncFilter(c)
    }
    root.addEventListener?.("input", c.boundSyncFilter)
    root.addEventListener?.("turbo:morph-element", c.boundSyncFilter)
    syncFilter(c)
  }

  // Tag-chip input (issue #203) — ONLY when the root names the hidden value
  // field (reactive_tags), so a component without one pays one attribute
  // read. The chip list is a CLIENT PROJECTION of the hidden field's
  // comma-joined value: connect seeds it (a plain replace re-connects with
  // the server-rendered value), and turbo:morph-element re-projects after an
  // in-place morph (the morph wrote server truth into the hidden field while
  // the chips DOM kept the pre-morph projection). Registered AFTER the
  // filter's listeners so a morph re-filters first and the tags pass then
  // re-marks selected options on the fresh visibility state.
  if (tagsEnabled(c)) {
    c.boundSyncTags = () => syncTags(c)
    root.addEventListener?.("turbo:morph-element", c.boundSyncTags)
    syncTags(c)
  }

  // JSON-mode nested rows (issue #208) — ONLY when the root owns a list with
  // `as: :json`, so a form without one pays a single probe (the show/filter/
  // tags gate precedent). ONE delegated input + change listener re-serializes
  // the rows into the hidden field on every owned edit (nestedAdd/Remove call
  // the sync directly; this covers typing into a row's fields). The connect
  // seed writes the initial array (a plain replace re-connects), and
  // turbo:morph-element re-seeds after an in-place morph (which keeps the
  // element connected, fires no Stimulus lifecycle, and may have rewritten
  // the rows to server truth while the hidden field kept its pre-morph value).
  if (nestedJsonEnabled(c)) {
    c.boundSyncNestedJson = (event) => syncNestedJson(c, event)
    c.boundSeedNestedJson = () => syncAllNestedJson(c)
    root.addEventListener?.("input", c.boundSyncNestedJson)
    root.addEventListener?.("change", c.boundSyncNestedJson)
    root.addEventListener?.("turbo:morph-element", c.boundSeedNestedJson)
    syncAllNestedJson(c)
  }
}

// Remove every listener connect() added, so a stray event after a Turbo
// morph/navigation never re-evaluates against a detached root.
export function disconnect(controller) {
  const c = contexts.get(controller)
  if (!c) return
  contexts.delete(controller)
  const root = c.root
  if (c.boundSyncShow) {
    root.removeEventListener?.("input", c.boundSyncShow)
    root.removeEventListener?.("change", c.boundSyncShow)
    root.removeEventListener?.("turbo:morph-element", c.boundSyncShow)
  }
  c.groupObserver?.disconnect()
  if (c.boundSyncOnComplete) {
    root.removeEventListener?.("input", c.boundSyncOnComplete)
    root.removeEventListener?.("change", c.boundSyncOnComplete)
    root.removeEventListener?.("turbo:morph-element", c.boundArmOnComplete)
  }
  if (c.boundSyncFilter) {
    root.removeEventListener?.("input", c.boundSyncFilter)
    root.removeEventListener?.("turbo:morph-element", c.boundSyncFilter)
  }
  if (c.boundSyncTags) root.removeEventListener?.("turbo:morph-element", c.boundSyncTags)
  if (c.boundSyncNestedJson) {
    root.removeEventListener?.("input", c.boundSyncNestedJson)
    root.removeEventListener?.("change", c.boundSyncNestedJson)
    root.removeEventListener?.("turbo:morph-element", c.boundSeedNestedJson)
  }
}

// Re-run the seeds that read field values, in connect() order — for a
// feature that changed those values after connect() ran (the draft restore).
// Each is the same re-sync a morph runs; on-complete re-ARMS without firing.
export function reseed(controller) {
  const c = contexts.get(controller)
  if (!c) return
  c.boundSyncShow?.()
  c.boundArmOnComplete?.()
  c.boundSyncFilter?.()
  c.boundSyncTags?.()
  c.boundSeedNestedJson?.()
}

// The Stimulus actions this module answers (the controller's own methods of
// the same names hand the event here).
function publicTagsAdd(controller, core, event) {
  return tagsAdd(ctx(controller, core), event)
}
function publicTagsPick(controller, core, event) {
  return tagsPick(ctx(controller, core), event)
}
function publicTagsRemove(controller, core, event) {
  return tagsRemove(ctx(controller, core), event)
}
function publicNestedAdd(controller, core, event) {
  return nestedAdd(ctx(controller, core), event)
}
function publicNestedRemove(controller, core, event) {
  return nestedRemove(ctx(controller, core), event)
}
function publicSyncNestedJson(controller, core, event) {
  return syncNestedJson(ctx(controller, core), event)
}
export {
  publicTagsAdd as tagsAdd,
  publicTagsPick as tagsPick,
  publicTagsRemove as tagsRemove,
  publicNestedAdd as nestedAdd,
  publicNestedRemove as nestedRemove,
  publicSyncNestedJson as syncNestedJson,
}

// The runtime's call-in for a conditional confirm: the message when its
// condition fires over this root's fields, else null.
export function confirmMessage(controller, core, confirmWhen) {
  return conditionalConfirmMessage(ctx(controller, core), confirmWhen)
}

// An id-only selector (the issue #159/#164 allowlist for anything that
// escapes the root).
const ID_SELECTOR = /^#[A-Za-z_][\w-]*$/

// The selector matching every OWNED-element show binding: single-field
// (data-reactive-show-field, issue #161) OR compound all:/any:
// (data-reactive-show, issue #176). Both the connect() gate and the sync walk
// use it so a compound-only root still enables the sync.
const SHOW_BINDING_SELECTOR = "[data-reactive-show-field], [data-reactive-show]"

// Evaluate a show binding's declared literal predicate (issue #161) against
// the controlling field's current value. Exactly one of the three predicate
// attrs decides: equals (value === literal), not (value !== literal), in
// (value ∈ a JSON string list). The vocabulary is fixed and literal-only —
// never an expression, so there is no eval surface (the reactive_show helper
// enforces the same shape loudly at render; this is the client half of the
// two-sided posture). Returns true/false for a decidable binding, or null for
// a malformed/missing predicate — the caller SKIPS a null so a hand-built or
// stale binding never flips visibility it doesn't understand (default-deny,
// like the op whitelist).
function showBindingMatches(el, value) {
  const equals = el.getAttribute("data-reactive-show-equals")
  if (equals !== null) return value === equals
  const not = el.getAttribute("data-reactive-show-not")
  if (not !== null) return value !== not
  const inRaw = el.getAttribute("data-reactive-show-in")
  if (inRaw !== null) {
    try {
      const list = JSON.parse(inRaw)
      if (Array.isArray(list)) return list.includes(value)
    } catch {
      // fall through to the warn below — malformed JSON and a non-array both skip
    }
    console.warn(`[phlex-reactive] malformed reactive_show in: list ${JSON.stringify(inRaw)} — skipped`)
    return null
  }
  // Numeric threshold predicates (issue #176 part B): gte/gt/lte/lt read the
  // literal off its own flat attr and compare Number(value) against it. Any
  // present numeric attr decides the binding — a non-numeric field value (NaN)
  // is false (hidden), and a non-numeric LITERAL warn-skips (null).
  for (const key of SHOW_NUMERIC_KEYS) {
    const raw = el.getAttribute(`data-reactive-show-${key}`)
    if (raw !== null) return numericPredicateMatches(key, raw, value)
  }
  console.warn("[phlex-reactive] a reactive_show binding declares no predicate — skipped")
  return null
}

// Parse a compound show binding's JSON payload (issue #176 part A). Malformed
// JSON degrades to null WITH a warn — a bad binding must never throw or blank
// the page (client-side default-deny), but a collision (two bindings' JSON
// mix-joined) is worth surfacing.
function parseShowCompound(raw) {
  try {
    const parsed = JSON.parse(raw)
    if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) return parsed
  } catch {
    // fall through to the warn
  }
  console.warn(`[phlex-reactive] malformed compound reactive_show payload ${JSON.stringify(raw)} — skipped`)
  return null
}

// Parse a data-reactive-on-complete payload (issue #226): a JSON array of
// { any: [[term, …], …], ops: [[op, args], …] } bindings. Malformed JSON, a
// non-array, or a binding missing either half degrades to [] WITH a warn — a
// bad payload must never throw or fire an op (client-side default-deny, the
// parseShowCompound posture).
function parseOnComplete(raw) {
  try {
    const list = JSON.parse(raw)
    if (
      Array.isArray(list) &&
      list.every((b) => b && typeof b === "object" && Array.isArray(b.any) && Array.isArray(b.ops))
    ) {
      return list
    }
  } catch {
    // fall through to the warn
  }
  console.warn(`[phlex-reactive] malformed reactive_on_complete payload ${JSON.stringify(raw)} — skipped`)
  return []
}

// Route a parsed data-reactive-show payload to the right evaluator. The 0.10
// wire is { any: [ [term,…], … ] } (DNF — groups are ARRAYS). For a stale tab
// still serving pre-0.10 HTML (deploy overlap), fall back to the 0.9.5 compound
// shape { all: [term,…] } / { any: [term,…] } where the values are flat TERM
// OBJECTS, not arrays. The nesting distinguishes them: DNF's any[0] is an Array.
// DELETE the legacy arm in 0.11.
function showPayloadMatches(payload, fieldValue) {
  if (!payload || typeof payload !== "object") return null
  const any = payload.any
  if (Array.isArray(any) && (any.length === 0 || Array.isArray(any[0]))) {
    return anyOfAllsMatches(any, fieldValue)
  }
  return legacyCompoundShowMatches(payload, fieldValue)
}

// LEGACY (0.9.5, deploy-overlap only — DELETE in 0.11): the flat all:/any:
// compound fold, where terms are objects (not groups). Preserved so a morph of
// stale pre-0.10 HTML doesn't go dead.
function legacyCompoundShowMatches(payload, fieldValue) {
  const connective = Array.isArray(payload.all) ? "all" : Array.isArray(payload.any) ? "any" : null
  if (!connective) return null
  const terms = payload[connective]
  if (terms.length === 0) return null
  const results = terms.map((term) => dnfTermMatches(term, fieldValue))
  return connective === "all" ? results.every(Boolean) : results.some(Boolean)
}

// A cross-root show target must be a single ID selector (issue #164) — the
// SAME shape the #159 mirror enforces (one shared regex), with its own warn so
// a refused show target is distinguishable in the console. The client half of
// the two-sided default-deny: reactive_show_targets raises at declare time; a
// hand-built wire attr must not widen the escape to class/compound selectors.
// A refused selector warns + skips — its siblings still apply.
function guardShowTargetSelector(selector) {
  if (typeof selector === "string" && ID_SELECTOR.test(selector)) return true
  console.warn(`[phlex-reactive] refused cross-root show target ${JSON.stringify(selector)} — skipped`)
  return false
}


// Whether this root owns a show binding (issue #161) or declares cross-root
// show targets (issue #164) — the connect() gate, so a component with
// neither pays only this probe (the #dirtyTrackingEnabled precedent). A
// NESTED root's bindings don't count: its own controller instance syncs them
// (issue #15 ownership). The targets attr is checked FIRST — one
// getAttribute, cheaper than the binding walk.
function showSyncEnabled(c) {
  if (c.root.getAttribute?.("data-reactive-show-targets")) return true
  // Single-field bindings carry -field; compound all:/any: bindings (issue
  // #176) carry data-reactive-show and have NO single controlling field, so
  // both selectors gate the sync.
  const nodes = c.root.querySelectorAll?.(SHOW_BINDING_SELECTOR) ?? []
  for (const el of nodes) if (c.core.owns(el)) return true
  for (const el of c.root.querySelectorAll?.(GROUP_BINDING_SELECTOR) ?? []) if (c.core.owns(el)) return true
  return false
}

// The connect() gate for completion bindings (issue #226) — one attribute read.
function onCompleteEnabled(c) {
  return !!c.root.getAttribute?.("data-reactive-on-complete")
}

// Parse-and-memoize the completion bindings, keyed on the RAW attr string:
// a morph that rewrote the payload re-parses and RESETS the latches (the
// morph listener's own arm pass then re-arms without firing). A removed
// attr yields [] silently; malformed JSON warns (in parseOnComplete).
function onCompleteBindings(c) {
  const raw = c.root.getAttribute?.("data-reactive-on-complete") ?? null
  if (raw !== c.onCompleteRaw) {
    c.onCompleteRaw = raw
    c.onCompleteParsed = raw == null ? [] : parseOnComplete(raw)
    c.onCompleteStates = c.onCompleteParsed.map(() => false)
  }
  return c.onCompleteParsed
}

// Evaluate every completion binding (issue #226) over the owned fields —
// the SAME memoized, scope-aware field resolver and DNF fold the show sync
// uses — and run each binding's ops on ITS OWN rising edge. `event` null
// (the connect/morph arm pass) updates the latches WITHOUT firing, so ops
// only ever run from a real user gesture. An undecidable payload (no
// groups) leaves its latch alone — default-deny, like every malformed-wire
// arm. Ops resolve through runOps's root-scoped targets; a missing to:
// defaults to "@root" (the $ops convention).
function syncOnComplete(c, event) {
  const bindings = onCompleteBindings(c)
  if (!bindings.length) return

  const fieldValue = fieldResolver(c, c.core.ownership())
  bindings.forEach((binding, i) => {
    const matches = anyOfAllsMatches(binding.any, fieldValue)
    if (matches === null) return
    const fire = matches && !c.onCompleteStates[i] && Boolean(event)
    c.onCompleteStates[i] = matches
    if (fire) {
      c.core.applyOps(binding.ops, "@root")
    }
  })
}

// Re-evaluate every OWNED show binding in one pass (issue #161): read the
// controlling field's current value, evaluate the declared literal predicate,
// toggle `hidden`. A full pass (not per-target) for the same reason as
// #scanDirty — a radio group's deselected radio fires no event — and because
// several bindings can hang off one field (the value read is memoized per
// pass). A binding whose field can't be resolved, or whose predicate is
// malformed, leaves visibility ALONE — a bad binding must never break or
// blank the page (client-side default-deny).
function syncShow(c) {
  if (typeof c.root?.querySelectorAll !== "function") return

  const owns = c.core.ownership()
  const scope = c.root.getAttribute?.("data-reactive-scope") || null
  // A memoized resolver shared by every binding in this pass — a field driving
  // several bindings (and several DNF terms) reads exactly once. Scope-aware:
  // a bare field `director` resolves as `[name="scope[director]"]` (issue #180).
  const fieldValue = fieldResolver(c, owns)
  for (const el of c.root.querySelectorAll(SHOW_BINDING_SELECTOR)) {
    if (!owns(el)) continue // a nested root's binding is its own controller's job

    // The 0.10 DNF payload (issue #180): data-reactive-show carries
    // { any: [ [term,…], … ] }. The legacy flat-attr and 0.9.5-compound read
    // arms live in showPayloadMatches/showBindingMatches for deploy overlap.
    const payloadRaw = el.getAttribute("data-reactive-show")
    if (payloadRaw !== null) {
      const match = showPayloadMatches(parseShowCompound(payloadRaw), fieldValue)
      if (match !== null) applyShowVisibility(c, el, match, owns, scope)
      continue
    }

    // LEGACY flat-attr binding (pre-0.10, deploy overlap — removed in 0.11).
    const name = el.getAttribute("data-reactive-show-field")
    if (!name) continue
    const value = fieldValue(name)
    if (value === null) continue // no owned field with that name — leave it be
    const match = showBindingMatches(el, value)
    if (match === null) continue // malformed predicate — warned + skipped
    applyShowVisibility(c, el, match, owns, scope)
  }

  // The group bindings (issue #319) and the cross-root pass (issue #164)
  // share the same owned-field memo, so a field driving several reads once.
  if (c.groups) syncGroups(c, fieldValue, owns, scope)
  syncShowTargets(c, fieldValue)
}

// Toggle `hidden` (and, when the binding declares data-reactive-show-disable,
// the `disabled` of every owned named control inside it) from a match result
// (issue #180). Disabling a hidden section's controls stops them submitting —
// the stale-value fix. A visible section re-enables them. Controls a nested
// reactive root owns are left alone (#15 ownership).
function applyShowVisibility(c, el, match, owns, scope) {
  el.hidden = !match
  if (el.getAttribute("data-reactive-show-disable") !== "true") return
  if (typeof el.querySelectorAll !== "function") return
  for (const control of el.querySelectorAll("input[name], select[name], textarea[name]")) {
    if (owns(control)) control.disabled = !match
  }
  // The element itself may be a named control (a bare field with a binding).
  if (el.name && owns(el)) el.disabled = !match
}

// Apply the declared cross-root show targets (issue #164) — the visibility
// parallel of #applyComputeMirrors. For each declared field: read the OWNED
// field's current value (never a nested root's — you can only drive outside
// visibility from a field this root owns), then for each "#id" → predicate
// entry: guard the selector id-only (warn-and-skip; the Ruby helper raised
// at declare time — two-sided default-deny), resolve it DOCUMENT-WIDE, and
// toggle `hidden`. A target id not on the page is silently skipped (an
// unrendered tab pane is normal); a malformed predicate warn-skips its one
// target while siblings still apply. With no map declared this is one
// getAttribute and out.
//
// A "#id" KEY (issue #209) is a TARGET-KEYED entry instead: its value is the
// same DNF payload data-reactive-show holds, folded with per-term owned-field
// reads — the multi-field cross-root case. The "#" prefix routes unambiguously
// (a field name may never start with "#"; the Ruby helper raises).
function syncShowTargets(c, fieldValue) {
  const map = parseShowTargets(c)
  for (const [name, targets] of Object.entries(map)) {
    if (name.startsWith("#")) {
      applyConditionsTarget(c, name, targets, fieldValue)
      continue
    }
    if (!targets || typeof targets !== "object" || Array.isArray(targets)) continue
    const value = fieldValue(name)
    if (value === null) continue // no owned field with that name — leave them be
    // Every target's terms share this one field, so a constant resolver folds
    // the group (issue #180): a target's value is a DNF GROUP (terms ANDed).
    // (A checked_* term asks for the group's count instead, issue #319.)
    const resolve = (_, count) => (count ? fieldValue(name, true) : value)
    for (const [selector, group] of Object.entries(targets)) {
      if (!guardShowTargetSelector(selector)) continue
      // 0.10 wire: the value is a DNF GROUP (an array of terms, ANDed).
      // LEGACY (0.9.5, deploy overlap — DELETE in 0.11): a flat predicate
      // OBJECT ({ equals/not/in/gte… }) routed through showPredicateMatches.
      let match
      if (Array.isArray(group)) {
        if (group.length === 0) {
          console.warn(`[phlex-reactive] malformed reactive_show_targets group for ${selector} — skipped`)
          continue
        }
        match = group.every((term) => dnfTermMatches(term, resolve))
      } else {
        const legacy = showPredicateMatches(group, value)
        if (legacy === null) {
          console.warn(`[phlex-reactive] malformed reactive_show_targets predicate for ${selector} — skipped`)
          continue
        }
        match = legacy
      }
      for (const node of document.querySelectorAll(selector)) node.hidden = !match
    }
  }
}

// Apply ONE target-keyed conditions entry (issue #209): "#id" → the DNF
// payload { any: [[term,…],…] }, folded by the SAME anyOfAllsMatches as an
// in-root reactive_show — each term reads its OWN owned field, a missing
// owned field reads as blank (fail-closed, the shared-fixture contract). A
// target whose referenced fields are ALL unowned is left alone — the
// single-field skip generalized (this root has nothing to evaluate with). A
// malformed payload warn-skips its one target while siblings still apply;
// the selector guard is the same id-only allowlist as every cross-root arm.
function applyConditionsTarget(c, selector, payload, fieldValue) {
  if (!guardShowTargetSelector(selector)) return
  const groups = payload && typeof payload === "object" && !Array.isArray(payload) ? payload.any : null
  const fields = dnfGroupFields(groups)
  if (fields === null) {
    console.warn(`[phlex-reactive] malformed reactive_show_targets conditions for ${selector} — skipped`)
    return
  }
  if (fields.every((name) => fieldValue(name) === null)) return // no owned field — leave it be
  const match = anyOfAllsMatches(groups, fieldValue)
  if (match === null) return // unreachable after dnfGroupFields, kept fail-closed
  for (const node of document.querySelectorAll(selector)) node.hidden = !match
}

// The declared cross-root show-target map (issue #164): a JSON object of
// { field: { "#id": predicate } } from data-reactive-show-targets (emitted
// by reactive_show_targets on the root). Absent degrades to {}; malformed
// degrades to {} WITH a warn — never a throw (the #parseComputeMirror
// contract), but never silent either: the likeliest cause is TWO
// reactive_show_targets calls on one root, whose JSON strings Phlex `mix`
// space-joined into an unparseable attr. The warn names the fix.
function parseShowTargets(c) {
  const raw = c.root.getAttribute?.("data-reactive-show-targets")
  if (!raw) return {}
  try {
    const parsed = JSON.parse(raw)
    if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) return parsed
  } catch {
    // fall through to the shared warn below
  }
  console.warn(
    "[phlex-reactive] malformed data-reactive-show-targets — ignored. " +
      "Did two reactive_show_targets calls collide on one root? Declare every field in ONE call: " +
      "reactive_show_targets(mode: { ... }, kind: { ... })"
  )
  return {}
}

// The current value of the OWNED field controlling a show binding, as the
// string the literal predicate compares against. Mirrors #collectFields'
// per-kind reads: a checkbox reports its checked state ("true"/"false" — its
// .value is the constant "on", and the checkbox wins over the hidden input
// Rails pairs with it); a radio group reports the CHECKED radio's value (""
// when none is); anything else reports .value first-wins. Returns null when
// no owned field carries the name — the caller then leaves visibility alone.
function showFieldValue(c, name, owns, scope) {
  let sawRadio = false
  let first = null
  for (const el of c.root.querySelectorAll(namedSelector(name, scope))) {
    if (!owns(el)) continue
    if (el.type === "checkbox") return el.checked ? "true" : "false"
    if (el.type === "radio") {
      if (el.checked) return el.value ?? ""
      sawRadio = true
      continue
    }
    first ??= el
  }
  if (first) return first.value ?? ""
  return sawRadio ? "" : null
}

// Scope (issue #180): a bare field `director` under `data-reactive-scope=
// "form"` resolves as `[name="form[director]"]`. A name already carrying a
// bracket (a raw wire name the author passed, like "ids[]") is used verbatim.
function namedSelector(name, scope) {
  return `[name="${scope && !name.includes("[") ? `${scope}[${name}]` : name}"]`
}

// The per-pass field resolver every DNF fold reads (show, enable, on-complete).
// fieldValue(name) is the field's string value; fieldValue(name, true) is how
// many owned boxes of that checkbox group are ticked (the checked_* terms,
// issue #319). Memoized, so a field driving several bindings reads once.
function fieldResolver(c, owns) {
  const scope = c.root.getAttribute?.("data-reactive-scope") || null
  const values = new Map()
  return (name, count) => {
    const key = count ? `#${name}` : name
    if (!values.has(key)) {
      values.set(key, count ? groupBoxes(c, name, owns, scope).filter((box) => box.checked).length : showFieldValue(c, name, owns, scope))
    }
    return values.get(key)
  }
}

// --- Bulk selection (issue #319) ---------------------------------------------
// A checkbox GROUP is the owned boxes sharing one name. Three bindings read it:
// the select-all header (data-reactive-select-all), the ticked count
// (data-reactive-count), and the checked_* terms any condition can use —
// reactive_enable (data-reactive-enable) flips the element's own `disabled`
// from one. They re-sync with the show pass: on every input/change, on a
// morph, and when boxes are added or removed (observeGroups).
const GROUP_BINDING_SELECTOR = "[data-reactive-enable], [data-reactive-select-all], [data-reactive-count]"

// Whether the root holds any group binding (owned or not — a stray nested
// one only costs the walk, which still skips it).
function hasGroups(c) {
  return !!c.root.querySelector?.(GROUP_BINDING_SELECTOR)
}

// The owned checkboxes of a group (a nested root's boxes are its own, #15).
function groupBoxes(c, name, owns, scope) {
  return [...c.root.querySelectorAll(namedSelector(name, scope))].filter((el) => el.type === "checkbox" && owns(el))
}

// A header's edit ticks or unticks every owned box of its group, and
// dispatches `input` + `change` on each one it flips so computes, shows and on-complete
// bindings see a real edit. The re-entrant change events are skipped by the
// show listener while this runs (c.flipping); it syncs once afterwards.
function flipGroup(c, header) {
  const group = header?.getAttribute?.("data-reactive-select-all")
  if (!group || !c.core.owns(header)) return
  const scope = c.root.getAttribute?.("data-reactive-scope") || null
  const flipped = groupBoxes(c, group, c.core.ownership(), scope).filter((box) => box !== header && box.checked !== header.checked)
  // Every box first, then the events: a listener (a checked-count
  // on_complete) must see the group's final count, never a half-flipped one.
  for (const box of flipped) box.checked = header.checked
  c.flipping = true
  try {
    for (const box of flipped) {
      // input then change, as a click does: computes listen on input.
      for (const type of ["input", "change"]) box.dispatchEvent?.(new Event(type, { bubbles: true }))
    }
  } finally {
    c.flipping = false
  }
}

// One pass over the owned group bindings: enable from its conditions, the
// count as text (change-guarded, like #mirrorText), and each header's
// checked/indeterminate from its group (the header itself never counts).
function syncGroups(c, fieldValue, owns, scope) {
  for (const el of c.root.querySelectorAll(GROUP_BINDING_SELECTOR)) {
    if (!owns(el)) continue
    const enable = el.getAttribute("data-reactive-enable")
    if (enable !== null) {
      const match = showPayloadMatches(parseShowCompound(enable), fieldValue)
      if (match !== null) el.disabled = !match
    }
    const counted = el.getAttribute("data-reactive-count")
    if (counted) {
      const text = String(fieldValue(counted, true))
      if (el.textContent !== text) el.textContent = text
    }
    const group = el.getAttribute("data-reactive-select-all")
    if (group) {
      const boxes = groupBoxes(c, group, owns, scope).filter((box) => box !== el)
      const ticked = boxes.filter((box) => box.checked).length
      el.checked = ticked > 0 && ticked === boxes.length
      el.indeterminate = ticked > 0 && ticked < boxes.length
    }
  }
}

// Boxes added or removed later — a stream append, a removal — fire no event,
// so a root with a group binding (a header, a count, an enable, or a show,
// show target or on_complete with a checked_* term) watches its subtree and
// re-syncs when a mutation adds or removes a checkbox: the show pass, and the
// on_complete latches re-armed without firing. Text writes (the count itself)
// never qualify, so it cannot loop. Installed once — at connect, or by the
// first morph that adds such a binding.
function observeGroups(c) {
  if (c.groupObserver || typeof MutationObserver !== "function") return
  const onRoot = (name) => c.root.getAttribute?.(`data-reactive-${name}`)?.includes("checked_")
  if (!c.root.querySelector?.(`${GROUP_BINDING_SELECTOR}, [data-reactive-show*=checked_]`) && !onRoot("show-targets") && !onRoot("on-complete")) return
  const boxIn = (node) => node.nodeType === 1 && (node.matches('input[type="checkbox"]') || !!node.querySelector('input[type="checkbox"]'))
  c.groupObserver = new MutationObserver((records) => {
    if (!records.some((r) => [...r.addedNodes, ...r.removedNodes].some(boxIn))) return
    c.boundSyncShow?.()
    c.boundArmOnComplete?.()
  })
  c.groupObserver.observe(c.root, { childList: true, subtree: true })
}

// Whether this root declares an option filter (issue #163) — the connect()
// gate. reactive_filter always emits input + option together, so requiring
// BOTH also default-denies a half-built hand-authored binding.
function filterEnabled(c) {
  return !!(
    c.root.getAttribute?.("data-reactive-filter-input") &&
    c.root.getAttribute?.("data-reactive-filter-option")
  )
}

// Whether a delegated input event came from the NAMED filter input (issue
// #163). Anything else — another field's keystroke, a target without
// matches() — skips the filter pass (the morph re-sync path bypasses this).
function filterInputEvent(c, event) {
  const selector = c.root.getAttribute("data-reactive-filter-input")
  return !!selector && typeof event.target?.matches === "function" && event.target.matches(selector)
}

// Re-apply the filter in one pass (issue #163): lowercase the named input's
// current value, toggle `hidden` on every OWNED option by a substring match
// against its haystack (data-reactive-filter-text, falling back to the
// option's own text), collapse any group whose every contained option is
// hidden, and reveal the empty target at 0 visible. A filtered-out option
// also loses its listnav highlight so Enter can never pick an invisible row.
// No owned input → leave visibility ALONE — a binding that can't resolve
// must never break or blank the page (client-side default-deny). All
// selectors resolve within this root, skipping nested reactive roots'
// elements (issue #15 ownership; the predicate is hoisted once per pass).
function syncFilter(c) {
  if (typeof c.root?.querySelectorAll !== "function") return
  const inputSelector = c.root.getAttribute("data-reactive-filter-input")
  const optionSelector = c.root.getAttribute("data-reactive-filter-option")
  if (!inputSelector || !optionSelector) return

  const owns = c.core.ownership()
  const input = [...c.root.querySelectorAll(inputSelector)].find(owns)
  if (!input) return

  const query = (input.value ?? "").trim().toLowerCase()
  let visible = 0
  for (const el of c.root.querySelectorAll(optionSelector)) {
    if (!owns(el)) continue // a nested root's option is its own controller's job
    const haystack = (el.getAttribute("data-reactive-filter-text") ?? el.textContent ?? "").toLowerCase()
    // An option whose tag is already selected (reactive_tags, issue #203)
    // stays hidden through every re-filter — clearing the query must not
    // resurface an already-added tag.
    const hidden =
      el.hasAttribute?.("data-reactive-tags-selected") || (query !== "" && !haystack.includes(query))
    el.hidden = hidden
    if (hidden) el.removeAttribute("data-reactive-highlighted")
    else visible++
  }

  const groupSelector = c.root.getAttribute("data-reactive-filter-group")
  if (groupSelector) {
    for (const group of c.root.querySelectorAll(groupSelector)) {
      if (!owns(group)) continue
      const contained = [...group.querySelectorAll(optionSelector)].filter(owns)
      // A group with no options isn't this filter's to decide — server state
      // stands (it may be a header the app toggles by other means).
      if (contained.length === 0) continue
      group.hidden = contained.every((el) => el.hidden)
    }
  }

  const emptySelector = c.root.getAttribute("data-reactive-filter-empty")
  if (emptySelector) {
    for (const el of c.root.querySelectorAll(emptySelector)) {
      if (owns(el)) el.hidden = visible > 0
    }
  }
}

// Whether this root declares a tag-chip binding (issue #203) — the connect()
// gate and every tags action's first check (an action bound without the root
// binding is default-denied, the filter posture).
function tagsEnabled(c) {
  return !!c.root.getAttribute?.("data-reactive-tags-field")
}

// Whether this root owns at least one JSON-mode nested list (issue #208) —
// the connect() gate. A cheap descendant probe: a form without one wires no
// input/change listeners. Ownership is re-checked per sync, so a stray match
// in a nested reactive root here is harmless (it just arms the listeners).
function nestedJsonEnabled(c) {
  if (typeof c.root?.querySelector !== "function") return false
  return !!c.root.querySelector("[data-reactive-nested-json]")
}

// The hidden input storing the comma-joined value, resolved fresh per use
// (a morph replaces nodes — never cache it) and OWNED by this root (issue
// #15). null when the selector resolves nothing — every caller then no-ops:
// a binding that can't resolve must never break the page.
function tagsField(c) {
  if (typeof c.root?.querySelectorAll !== "function") return null
  const selector = c.root.getAttribute("data-reactive-tags-field")
  if (!selector) return null
  const owns = c.core.ownership()
  return [...c.root.querySelectorAll(selector)].find(owns) ?? null
}

// Parse the field's comma-joined value into the canonical tag list: split,
// trim, drop blanks, dedupe case-insensitively KEEPING the first casing (the
// server may have stored a ragged value — the projection normalizes without
// rewriting the field, so we never fight server truth).
function tagsRead(c, field) {
  const seen = new Set()
  const tags = []
  for (const part of String(field.value ?? "").split(",")) {
    const tag = part.trim()
    if (tag === "" || seen.has(tag.toLowerCase())) continue
    seen.add(tag.toLowerCase())
    tags.push(tag)
  }
  return tags
}

// Append any NEW tags (trimmed, non-blank, not already present under the
// case-insensitive dedupe) and write the field once. Returns whether
// anything was actually added — callers only clear the query input then.
function tagsAddValues(c, values) {
  const field = tagsField(c)
  if (!field) return false

  const tags = tagsRead(c, field)
  const seen = new Set(tags.map((tag) => tag.toLowerCase()))
  let added = false
  for (const value of values) {
    const tag = String(value ?? "").trim()
    if (tag === "" || seen.has(tag.toLowerCase())) continue
    seen.add(tag.toLowerCase())
    tags.push(tag)
    added = true
  }
  if (added) tagsWrite(c, field, tags)
  return added
}

// The ONE writer: join, store, dispatch a real bubbling `input` on the field
// (the set-value + dispatch contract, issue #183 — dirty tracking,
// reactive_show, and compute all see the change), then re-project.
function tagsWrite(c, field, tags) {
  field.value = tags.join(",")
  if (typeof field.dispatchEvent === "function") {
    field.dispatchEvent(new Event("input", { bubbles: true }))
  }
  syncTags(c)
}

// The query input the tags widget resets after a pick — the SAME input that
// drives reactive_filter (a tags widget without filtering has none; the
// caller then skips the reset).
function tagsQueryInput(c) {
  if (typeof c.root?.querySelectorAll !== "function") return null
  const selector = c.root.getAttribute("data-reactive-filter-input")
  if (!selector) return null
  const owns = c.core.ownership()
  return [...c.root.querySelectorAll(selector)].find(owns) ?? null
}

// Re-project the hidden field into the DOM (issue #203): rebuild the chip
// list from the <template> and mark/hide the options whose tag is already
// selected. The field is the single source of truth — this never writes it.
function syncTags(c) {
  const field = tagsField(c)
  if (!field) return
  const tags = tagsRead(c, field)
  const owns = c.core.ownership()
  tagsRenderChips(c, tags, owns)
  tagsMarkOptions(c, tags, owns)
}

// Rebuild the chip list: clear the container and clone one chip per tag from
// the server-owned template. The tag lands in the clone's
// [data-reactive-tag-text] node via textContent (XSS-safe by construction —
// never innerHTML, the reactive_text posture), and every tagsRemove trigger
// in the clone gets the tag as its param. A missing list is a chip-less
// widget (fine — the value still maintains); a missing/empty template warns
// ONCE (a half-built binding should be loud, but never per-keystroke).
function tagsRenderChips(c, tags, owns) {
  const list = [...c.root.querySelectorAll("[data-reactive-tags-list]")].find(owns)
  if (!list) return

  const template = [...c.root.querySelectorAll("[data-reactive-tags-template]")].find(owns)
  const chipProto = template?.content?.firstElementChild
  if (!chipProto) {
    if (!c.tagsWarnedTemplate) {
      console.warn(
        "[phlex-reactive] reactive_tags: no chip <template data-reactive-tags-template> found in this root — " +
          "chips will not render (the hidden field still updates). Add a template with a " +
          "[data-reactive-tag-text] node and a reactive_tags_remove button."
      )
      c.tagsWarnedTemplate = true
    }
    return
  }

  while (list.firstChild) list.removeChild(list.firstChild)
  for (const tag of tags) {
    const chip = chipProto.cloneNode(true)
    chip.setAttribute?.("data-reactive-tag", tag)
    const sink = chip.matches?.("[data-reactive-tag-text]")
      ? chip
      : (chip.querySelectorAll?.("[data-reactive-tag-text]") ?? [])[0]
    if (sink) sink.textContent = tag
    const removers = [...(chip.querySelectorAll?.('[data-action*="reactive#tagsRemove"]') ?? [])]
    if (chip.matches?.('[data-action*="reactive#tagsRemove"]')) removers.push(chip)
    for (const remover of removers) remover.setAttribute?.("data-reactive-tag-param", tag)
    list.appendChild(chip)
  }
}

// Hide + mark every owned option whose DECLARED tag is already selected
// (data-reactive-tags-selected — #syncFilter keeps it hidden through
// re-filters), and resurface an option WE hid when its tag is removed. Only
// marker-carrying options are un-hidden — an option hidden by the filter or
// the server stays as-is. With a filter bound, one final #syncFilter re-folds
// groups/empty against the new selected set.
function tagsMarkOptions(c, tags, owns) {
  const selected = new Set(tags.map((tag) => tag.toLowerCase()))
  for (const el of c.root.querySelectorAll("[role=option]")) {
    if (!owns(el)) continue
    const tag = el.getAttribute?.("data-reactive-tag-param")
    if (!tag) continue
    if (selected.has(tag.toLowerCase())) {
      el.setAttribute("data-reactive-tags-selected", "true")
      el.hidden = true
      el.removeAttribute?.("data-reactive-highlighted")
    } else if (el.hasAttribute?.("data-reactive-tags-selected")) {
      el.removeAttribute("data-reactive-tags-selected")
      if (!filterEnabled(c)) el.hidden = false
    }
  }
  if (filterEnabled(c)) syncFilter(c)
}

// A fresh index per nested-row add (issue #208) — strictly monotonic and
// clock-seeded, so it can never collide with server-rendered integer indexes
// (0..n) NOR with a rapid same-millisecond double add.
function nextNestedIndex(c) {
  c.nestedIndex = Math.max(c.nestedIndex + 1, Date.now())
  return c.nestedIndex
}

// Swap every NEW_ROW in the clone's name/id/for for the fresh index, so the
// row posts as its own `…_attributes[<index>][field]` group and labels keep
// pointing at their (renumbered) inputs.
function renumberNestedRow(c, row, index) {
  const nodes = [row, ...(row.querySelectorAll?.("*") ?? [])]
  for (const el of nodes) {
    for (const attr of ["name", "id", "for"]) {
      const value = el.getAttribute?.(attr)
      if (value && value.includes("NEW_ROW")) el.setAttribute?.(attr, value.replaceAll("NEW_ROW", String(index)))
    }
  }
}

// A half-built nested-rows binding should be loud, but never per-click.
function warnNestedOnce(c, assoc) {
  if (c.nestedWarned) return
  console.warn(
    `[phlex-reactive] nested rows: no owned [data-reactive-nested-list="${assoc}"] container + ` +
      `<template data-reactive-nested-template="${assoc}"> pair found in this root — the add ` +
      "trigger did nothing. Render both inside the same reactive root (reactive_nested_list / " +
      "reactive_nested_template)."
  )
  c.nestedWarned = true
}

// Fill-then-add (issue #208): copy each source control's value into the
// matching cloned-row field, keyed by the trailing bracket segment of the
// field's name (#nestedJsonKey — the SAME inference JSON mode uses, so the
// two features can't drift). Sources resolve root-scoped and owned (#15); an
// unresolved source or an unmatched key is silently skipped (the row still
// adds — a half-mapped binding must never throw on click). Returns the FIRST
// source control read (for focus), or null. With `clear`, resets every source
// it read via the set-value + dispatch contract (#183) so dirty/show/compute
// observe the reset.
function seedNestedRow(c, row, fromJson, clear) {
  if (!fromJson) return null
  let map
  try {
    map = JSON.parse(fromJson)
  } catch {
    return null
  }
  if (!map || typeof map !== "object") return null

  const owns = c.core.ownership()
  const rowFields = [...(row.querySelectorAll?.("input, select, textarea") ?? [])]
  const sources = []
  for (const [key, selector] of Object.entries(map)) {
    const source = [...(c.root.querySelectorAll?.(selector) ?? [])].find(owns)
    if (!source) continue
    const target = rowFields.find((field) => nestedJsonKey(c, field.getAttribute?.("name")) === key)
    if (!target) continue
    seedNestedField(c, target, source)
    sources.push(source)
  }
  if (clear) for (const source of sources) clearNestedSource(c, source)
  return sources[0] ?? null
}

// Copy a source control's value into a cloned-row field, then dispatch a
// bubbling `input` (the set-value + dispatch contract, #183). Checkbox ↔
// checkbox copies the checked state; every other target takes the source's
// submit-shaped value (#nestedFieldValue), so a checkbox source feeding a
// text field lands "on"/"" exactly as a submit would.
function seedNestedField(c, target, source) {
  if (target.type === "checkbox") {
    target.checked = source.type === "checkbox" ? !!source.checked : nestedFieldValue(c, source) !== ""
  } else {
    target.value = nestedFieldValue(c, source)
  }
  if (typeof target.dispatchEvent === "function") {
    target.dispatchEvent(new Event("input", { bubbles: true }))
  }
}

// Reset a source control after a fill-then-add (issue #208), dispatching a
// bubbling `input` so dirty tracking / reactive_show / compute see the reset.
function clearNestedSource(c, source) {
  if (source.type === "checkbox") source.checked = false
  else source.value = ""
  if (typeof source.dispatchEvent === "function") {
    source.dispatchEvent(new Event("input", { bubbles: true }))
  }
}

// Resolve %{field} placeholders in a confirm message from a row's field map
// (issue #222). Ruby-style %{name} tokens; an unresolved key is left verbatim
// (a visible, debuggable placeholder — never an empty hole or a throw). A
// message with no placeholders returns unchanged, so this is inert for every
// server-rendered (already-interpolated) confirm string.
function interpolateConfirm(c, message, fields) {
  if (!message.includes("%{")) return message
  return message.replace(/%\{(\w+)\}/g, (whole, key) =>
    Object.prototype.hasOwnProperty.call(fields, key) ? fields[key] : whole,
  )
}

// The remove itself, shared by the confirmed and no-confirm paths. Draft rows
// leave the DOM; a persisted row (a hidden [_destroy] input present) is marked
// "1" + hidden instead (set-value + dispatch contract, #183), so Rails destroys
// it on save. Then re-sync every owned JSON-mode list (#208) — an absent row
// IS the removal; a form without a JSON list iterates an empty set and exits.
function removeNestedRow(c, row) {
  const destroy = [...(row.querySelectorAll?.('input[name$="[_destroy]"]') ?? [])][0]
  if (destroy) {
    destroy.value = "1"
    if (typeof destroy.dispatchEvent === "function") {
      destroy.dispatchEvent(new Event("input", { bubbles: true }))
    }
    row.hidden = true
  } else {
    row.parentNode?.removeChild?.(row)
  }

  syncAllNestedJson(c)
}

// Serialize every owned JSON-mode list into its hidden field. The connect
// seed and the input/remove re-syncs funnel through here so one place owns
// the "DOM rows → JSON field" projection.
function syncAllNestedJson(c) {
  if (typeof c.root?.querySelectorAll !== "function") return
  const owns = c.core.ownership()
  for (const list of [...c.root.querySelectorAll("[data-reactive-nested-json]")].filter(owns)) {
    syncNestedJsonList(c, list.getAttribute("data-reactive-nested-json"))
  }
}

// The hidden field a JSON-mode list mirrors into — resolved fresh (a morph
// replaces nodes, never cache it) and OWNED by this root (#15). null when
// the selector resolves nothing, so the caller no-ops (a half-built binding
// must never break the page).
function nestedJsonField(c, list) {
  const selector = list.getAttribute?.("data-reactive-nested-json-field")
  if (!selector) return null
  const owns = c.core.ownership()
  return [...c.root.querySelectorAll(selector)].find(owns) ?? null
}

// One row → { key: value } over its named form controls. The JSON key is the
// trailing bracket segment of each control's name (order[todos_attributes]
// [3][title] → "title"; a bare `title` → "title"), the "infer from input
// names" contract. The [_destroy] control is dropped (JSON has no destroy
// marker). Later inputs with the same key win (last-wins, the DOM order).
// Like a real submit (#299): an unchecked radio, a disabled control (its own
// flag or a <fieldset disabled> ancestor: :disabled) and a nested reactive
// root's control are skipped.
function nestedRowObject(c, row) {
  const obj = {}
  const owns = c.core.ownership()
  for (const el of [...(row.querySelectorAll?.("input, select, textarea") ?? [])]) {
    if (el.matches(":disabled") || (el.type === "radio" && !el.checked) || !owns(el)) continue
    const key = nestedJsonKey(c, el.getAttribute?.("name"))
    if (key === null || key === "_destroy") continue
    obj[key] = nestedFieldValue(c, el)
  }
  return obj
}

// The trailing bracket segment of a field name (the inferred JSON key), or
// the bare name when it carries no brackets. null for a nameless control
// (a bare button, an unnamed helper input) — skipped by the caller.
function nestedJsonKey(c, name) {
  if (!name) return null
  const match = name.match(/\[([^\][]+)\]$/)
  return match ? match[1] : name
}

// A form control's submitted value: an unchecked checkbox contributes "" (it
// wouldn't post at all), a checked one its value (default "on"); everything
// else its .value. Keeps the JSON shape close to what a real form submit
// would carry for the same control.
function nestedFieldValue(c, el) {
  if (el.type === "checkbox") return el.checked ? (el.value || "on") : ""
  return el.value ?? ""
}

// Project ONE JSON-mode list's surviving rows into its hidden field. Each
// row becomes an object keyed by the trailing bracket segment of its inputs'
// names (…[title] → "title"); a hidden/_destroy-marked row is skipped (an
// absent row IS the removal — JSON carries no destroy marker). The write
// uses the set-value + dispatch contract (issue #183) so dirty tracking,
// reactive_show, and compute see the change — but only when the value
// actually changed, so a connect seed on an already-correct field is silent.
function syncNestedJsonList(c, assoc) {
  const owns = c.core.ownership()
  const list = [...c.root.querySelectorAll(`[data-reactive-nested-list="${assoc}"]`)].find(owns)
  if (!list) return
  const field = nestedJsonField(c, list)
  if (!field) return

  const rows = []
  for (const row of [...(list.querySelectorAll?.("[data-reactive-nested-row]") ?? [])]) {
    if (!owns(row) || row.hidden) continue
    rows.push(nestedRowObject(c, row))
  }

  const next = JSON.stringify(rows)
  if (field.value === next) return
  field.value = next
  if (typeof field.dispatchEvent === "function") {
    field.dispatchEvent(new Event("input", { bubbles: true }))
  }
}

// Tag-chip input (issue #203) — the composed combobox/tags primitive. The
// root's data-reactive-tags-field names the hidden input that stores the
// COMMA-JOINED value; these three actions are its only writers. All of it is
// FORM state (like text in an input) — no token, no POST: the surrounding
// form submit carries the joined value. The chip list is re-projected from
// the field on every write (#syncTags), so the field stays the single source
// of truth.
//
// Enter on the query input: add the TYPED text — unless this Enter belongs
// to listnav (reactive_tags_add composes after reactive_listnav on the same
// keydown.enter). Two guards make the composition order-independent:
// defaultPrevented means listnavPick ALREADY picked the highlighted option
// (adding the typed text too would double-add); a still-visible highlighted
// option means listnavPick is ABOUT to pick it (when tagsAdd is bound
// first). Past the guards, Enter is OURS — preventDefault unconditionally so
// it can never submit the enclosing form (blank input included). A
// comma-separated paste splits into individual tags (the value is
// comma-joined, so a comma can never be part of one tag). The input clears
// only when something was actually added — a duplicate keeps the typed text
// for correction.
function tagsAdd(c, event) {
  if (!tagsEnabled(c)) return
  if (event?.defaultPrevented) return
  if (c.core.listnavOptions(event).some((el) => el.hasAttribute?.("data-reactive-highlighted"))) return
  event?.preventDefault?.()

  const input = event?.currentTarget ?? event?.target
  if (!input) return
  const added = tagsAddValues(c, String(input.value ?? "").split(","))
  if (!added) return
  input.value = ""
  if (filterEnabled(c)) syncFilter(c)
}

// Click (or listnav Enter, which CLICKS the highlighted option) on a
// preloaded option: add its DECLARED tag (data-reactive-tag-param — set by
// reactive_tags_option, never free text). After a successful add, reset the
// query so the next tag starts from the full list: clear the filter input,
// re-narrow, and hand focus back for continued typing.
function tagsPick(c, event) {
  if (!tagsEnabled(c)) return
  event?.preventDefault?.()

  const trigger = event?.currentTarget ?? event?.target
  const tag = trigger?.getAttribute?.("data-reactive-tag-param")
  if (!tag) return
  if (!tagsAddValues(c, [tag])) return

  const input = tagsQueryInput(c)
  if (!input) return
  input.value = ""
  syncFilter(c)
  input.focus?.()
}

// Click on a chip's remove button: drop its tag (case-insensitive match, the
// dedupe convention) from the hidden value. The re-projection removes the
// chip and resurfaces the option. Removing an absent tag is a no-op.
function tagsRemove(c, event) {
  if (!tagsEnabled(c)) return
  event?.preventDefault?.()

  const trigger = event?.currentTarget ?? event?.target
  const tag = trigger?.getAttribute?.("data-reactive-tag-param")
  if (!tag) return
  const field = tagsField(c)
  if (!field) return

  const tags = tagsRead(c, field)
  const next = tags.filter((t) => t.toLowerCase() !== tag.toLowerCase())
  if (next.length === tags.length) return
  tagsWrite(c, field, next)
}

// Draft nested-attribute rows (issue #208) — the "new parent + child rows"
// window. The rows are FORM state (the reactive_tags posture): no token, no
// POST, ever — the surrounding REAL form submit carries Rails'
// accepts_nested_attributes_for names and the server reconciles parent +
// rows in ONE create. Add clones the association's server-owned
// <template data-reactive-nested-template="assoc"> row, swaps every NEW_ROW
// in the clone's name/id/for for a fresh unique index (each row posts as its
// own `…_attributes[<index>][field]` group), appends it to the owned
// [data-reactive-nested-list="assoc"] container, and focuses the new row's
// first field. Several collections can share one root — everything is keyed
// by the association name the trigger carries.
function nestedAdd(c, event) {
  event?.preventDefault?.()
  const trigger = event?.currentTarget ?? event?.target
  const assoc = trigger?.getAttribute?.("data-reactive-association-param")
  if (!assoc) return
  if (typeof c.root?.querySelectorAll !== "function") return

  const owns = c.core.ownership()
  const list = [...c.root.querySelectorAll(`[data-reactive-nested-list="${assoc}"]`)].find(owns)
  const template = [...c.root.querySelectorAll(`[data-reactive-nested-template="${assoc}"]`)].find(owns)
  const proto = template?.content?.firstElementChild
  if (!list || !proto) {
    warnNestedOnce(c, assoc)
    return
  }

  const row = proto.cloneNode(true)
  renumberNestedRow(c, row, nextNestedIndex(c))
  list.appendChild(row)

  // Fill-then-add (issue #208 Scenario A): seed the cloned row from named
  // source controls OUTSIDE the row, then (optionally) clear the sources.
  // Runs AFTER renumber+append so a seeded field's name already carries its
  // final `[<index>][field]` form — the key match agrees with what JSON mode
  // reads. `seeded` is the FIRST source we cleared/read, so fill-then-add can
  // return focus to the sources instead of stealing it into the new row.
  const fromJson = trigger?.getAttribute?.("data-reactive-nested-from-param")
  const clear = trigger?.getAttribute?.("data-reactive-nested-clear-param") === "true"
  const firstSource = seedNestedRow(c, row, fromJson, clear)

  // Focus: inline-edit (no from:) focuses the new row's first field so you
  // type INTO it; fill-then-add keeps focus on the sources (the first one) so
  // you keep entering the next item — stealing focus would break that loop.
  if (fromJson) firstSource?.focus?.()
  else [...(row.querySelectorAll?.("input, select, textarea") ?? [])][0]?.focus?.()

  // JSON mode (issue #208): a freshly-added row must land in the hidden field
  // immediately (seeded values included), so the serialized array reflects the
  // DOM even before the first keystroke. A no-op when not `as: :json`.
  if (list.getAttribute?.("data-reactive-nested-json") === assoc) syncNestedJsonList(c, assoc)
}

// Remove the trigger's closest row wrapper. A DRAFT row (no [_destroy]
// input) leaves the DOM — it was never persisted, so removing its fields IS
// the removal. A PERSISTED row (an edit form rendered a hidden [_destroy]
// input via nested_field_name) is marked "1" and hidden instead — Rails
// destroys it on save. The mark dispatches a real bubbling `input` (the
// set-value + dispatch contract, issue #183) so dirty tracking/compute see it.
function nestedRemove(c, event) {
  event?.preventDefault?.()
  const trigger = event?.currentTarget ?? event?.target
  const row = trigger?.closest?.("[data-reactive-nested-row]")
  if (!row) return
  // The closest() walk must not escape this root — a root can itself sit
  // inside ANOTHER collection's row (the issue #15 closest-form posture).
  if (row.closest?.('[data-controller~="reactive"]') !== c.root) return

  // Confirm gate (issue #218): reactive_nested_remove(confirm:) emits the SAME
  // data-reactive-confirm[-when]-param the other triggers do (nestedRemove reads
  // params via getAttribute, not event.params, so pull them off the trigger),
  // routed through the SAME #effectiveConfirmMessage + confirmResolver seam. A
  // static string always shows; a conditional Hash fires only when it matches,
  // else null. No confirm attr → null → the immediate-remove fast path.
  const confirm = trigger?.getAttribute?.("data-reactive-confirm-param")
  const confirmWhen = trigger?.getAttribute?.("data-reactive-confirm-when-param")
  const rawMessage = confirm || (confirmWhen ? conditionalConfirmMessage(c, confirmWhen) : null)
  if (!rawMessage) return removeNestedRow(c, row)

  // Per-row confirm interpolation (issue #222). A row added client-side is a
  // cloneNode of the <template>, and the clone carries the TEMPLATE's confirm
  // string verbatim — the renumber/seed steps never rewrite the confirm attr.
  // So resolve %{field} placeholders here, from THIS row's live field values
  // (read now, not at clone time, so a later edit is reflected). An unresolved
  // key is left as its literal %{key} (debuggable, never throws). Server-
  // rendered rows already interpolate server-side, so their finished strings
  // carry no %{}; this is a no-op for them.
  const fields = nestedRowObject(c, row)
  const message = interpolateConfirm(c, rawMessage, fields)

  // Gate through the overridable confirmResolver (issues #52/#55/#178) — a
  // themed dialog set with setConfirmResolver covers this trigger too. Pass the
  // row context (issue #222, superset of proposal 3) as an optional 2nd arg so
  // a power-user override can build the string itself; the message is already
  // interpolated for the default window.confirm path. Call the resolver INSIDE
  // the chain so even a SYNCHRONOUS override throw is a cancel (like a dismissed
  // dialog), and remove ONLY on a truthy resolution.
  return c.core.confirm(message, { el: trigger, row, fields }).then((ok) => {
    if (ok) removeNestedRow(c, row)
  })
}

// JSON-mode nested rows (issue #208) — the delegated input/change handler.
// An app whose controller parses a serialized JSON param instead of Rails'
// accepts_nested_attributes_for opts a list into `as: :json`; the client
// then mirrors that list's rows into ONE hidden field as a JSON array on
// every owned edit. Public so Stimulus can bind it; a no-op unless the
// edited field belongs to a JSON-mode list this root owns.
function syncNestedJson(c, event) {
  const target = event?.target
  if (!target || !c.core.owns(target)) return
  // Re-serialize every JSON-mode list (an edit could touch any of them; the
  // per-list owned-row scan is cheap and keeps this handler association-free).
  syncAllNestedJson(c)
}

// The numeric threshold keys (issue #176 part B) — the client half of the Ruby
// SHOW_NUMERIC_KEYS. Order-independent; the evaluator reads the one that's
// present. Each coerces BOTH sides to Number and compares.
const SHOW_NUMERIC_KEYS = ["gte", "gt", "lte", "lt"]

// The length predicate keys (issue #226) — the client half of Ruby's
// ShowConditions::LENGTH_KEYS. Length is counted in CODEPOINTS
// ([...str].length), NOT UTF-16 code units (str.length), so Ruby's
// String#length and this evaluator agree on multibyte values — the shared
// fixture's emoji vector proves it.
const SHOW_LENGTH_KEYS = ["len_eq", "len_gte", "len_gt", "len_lte", "len_lt"]

// The checked-count keys (issue #319) — the client half of Ruby's
// ShowConditions::CHECKED_KEYS: how many owned boxes of a group are ticked.
const SHOW_CHECKED_KEYS = ["checked_eq", "checked_gte", "checked_gt", "checked_lte", "checked_lt"]

// Evaluate one count predicate (len_* or checked_*). A count is a TOTAL
// function (blank/absent → 0), so every field value is decidable — no
// fail-closed special case like the numeric thresholds ({ length: 0 }
// legitimately matches a blank field). A non-Integer LITERAL is a malformed
// binding — warn-skip (null), default-deny.
function countPredicateMatches(key, literal, count) {
  if (!Number.isInteger(literal)) {
    console.warn(`[phlex-reactive] reactive_show ${key}: needs an integer literal, got ${JSON.stringify(literal)} — skipped`)
    return null
  }
  switch (key.slice(key.indexOf("_") + 1)) {
    case "eq":
      return count === literal
    case "gte":
      return count >= literal
    case "gt":
      return count > literal
    case "lte":
      return count <= literal
    case "lt":
      return count < literal
    default:
      return null
  }
}

// Evaluate one numeric threshold predicate against a field value. Returns
// true/false for a decidable comparison, or null when the LITERAL itself is
// non-numeric (a malformed binding — warn-skip, default-deny). A non-numeric
// FIELD value (empty/blank/garbage) is treated as NaN → false: the
// reveal-on-threshold notice stays hidden, the safe default. Shared by the
// owned-binding evaluator (raw string literal off an attr) and the
// cross-root/compound evaluator (a literal that arrived as a JSON number or
// string).
function numericPredicateMatches(key, literal, value) {
  const rhs = Number(literal)
  if (Number.isNaN(rhs)) {
    console.warn(`[phlex-reactive] reactive_show ${key}: needs a numeric literal, got ${JSON.stringify(literal)} — skipped`)
    return null
  }
  // A blank/whitespace field value must fail closed. Number("") and
  // Number("   ") are 0 (NOT NaN), so a bare Number()+isNaN check would wrongly
  // reveal a `lte:`/`lt:`/`gte: 0` binding on an EMPTY field. Force the
  // empty/blank case to NaN so the "blank → hidden" contract holds for every
  // operator, not just the ones where 0 happens to fail the comparison.
  const trimmed = value == null ? "" : String(value).trim()
  const n = trimmed === "" ? NaN : Number(trimmed)
  if (Number.isNaN(n)) return false
  switch (key) {
    case "gte":
      return n >= rhs
    case "gt":
      return n > rhs
    case "lte":
      return n <= rhs
    case "lt":
      return n < rhs
    default:
      return null
  }
}

// Evaluate an ALREADY-PARSED show predicate object (issue #164) — the
// reactive_show_targets map embeds { equals/not/in } directly in its JSON, so
// unlike showBindingMatches there are no attrs to read or re-parse. The same
// literal-only vocabulary; anything else (empty, unknown keys, a non-array
// in:) returns null and the caller warn-skips that target (default-deny — a
// hand-built map entry must never flip visibility it doesn't declare).
function showPredicateMatches(pred, value) {
  if (!pred || typeof pred !== "object") return null
  if (typeof pred.equals === "string") return value === pred.equals
  if (typeof pred.not === "string") return value !== pred.not
  if (Array.isArray(pred.in)) return pred.in.includes(value)
  // Numeric threshold predicates (issue #176 part B): the literal arrives as a
  // JSON number (or a numeric string) embedded in the predicate object — one
  // shared numericPredicateMatches with the owned-binding evaluator.
  for (const key of SHOW_NUMERIC_KEYS) {
    if (key in pred) return numericPredicateMatches(key, pred[key], value)
  }
  // Length predicates (issue #226): codepoint count vs an Integer literal.
  for (const key of SHOW_LENGTH_KEYS) {
    if (key in pred) return countPredicateMatches(key, pred[key], [...String(value ?? "")].length)
  }
  return null
}

// Evaluate one DNF TERM against a resolved field value (issue #180). A missing
// field (null) or a malformed/unknown predicate folds to FALSE — fail-closed
// (default-deny): a broken AND term can't pass, a broken OR term can't reveal.
function dnfTermMatches(term, fieldValue) {
  if (!term || typeof term !== "object" || typeof term.field !== "string") return false
  // A checked_* term (issue #319) counts the group's ticked boxes: the
  // resolver's count form, or — from collected fields (a conditional confirm)
  // — the group's array of checked values (a lone box's true/false is 1/0).
  const checked = SHOW_CHECKED_KEYS.find((key) => key in term)
  if (checked) {
    const n = fieldValue(term.field, true)
    return countPredicateMatches(checked, term[checked], Array.isArray(n) ? n.length : Number(n) || 0) === true
  }
  // An absent owned field reads as "" — identical to the server evaluator
  // (ShowConditions.match? treats a missing field as blank). This keeps the
  // Ruby first-paint and the client live-toggle in exact agreement (the shared
  // fixture proves it). A malformed predicate still folds to false.
  const value = fieldValue(term.field) ?? ""
  return showPredicateMatches(term, value) === true
}

// Evaluate a DNF show payload (issue #180): { any: [group, …] } where each
// GROUP is an array of terms (terms AND within a group, groups OR). Returns
// true/false for a decidable payload, or null for a malformed one (no groups)
// so the caller warn-skips and leaves visibility alone. This is the ONE shape
// the 0.10 wire emits; showPayloadMatches routes the legacy shapes here or to
// the compatibility arm below.
function anyOfAllsMatches(groups, fieldValue) {
  if (!Array.isArray(groups) || groups.length === 0) return null
  // groups OR; within a group, terms AND (an empty group can't decide → false).
  return groups.some((group) => Array.isArray(group) && group.length > 0 &&
    group.every((term) => dnfTermMatches(term, fieldValue)))
}

// Every field a DNF payload's groups reference (issue #209) — drives the
// "leave the target alone when NO referenced field is owned" skip, the
// single-field-target skip generalized. Returns null for a malformed payload
// (no groups, or no term names a field) so the caller warn-skips instead of
// toggling on garbage (default-deny, like every other malformed-wire arm).
function dnfGroupFields(groups) {
  if (!Array.isArray(groups) || groups.length === 0) return null
  const fields = new Set()
  for (const group of groups) {
    if (!Array.isArray(group)) continue
    for (const term of group) {
      if (term && typeof term === "object" && typeof term.field === "string") fields.add(term.field)
    }
  }
  return fields.size > 0 ? [...fields] : null
}

// Resolve the effective confirm message (issue #179). A plain string is the
// static #52 form (always shown). A confirmWhen JSON payload is the CONDITIONAL
// form — evaluated over the SAME collected fields reactive_compute reads — and
// returns the message ONLY when it fires, else null (proceed, no dialog):
//   { groups, message }    — the reactive_show conditions fold (anyOfAllsMatches)
//   { predicate, message } — a registered fn (setConfirmPredicate) over the fields
// A missing predicate warns and returns null (PROCEED without a dialog) — the
// compute unknown-reducer posture. This is soft-validation UX; the endpoint's
// authorize/default-deny is the real gate, so failing OPEN here never grants
// anything the server wouldn't already allow.
function conditionalConfirmMessage(c, confirmWhen) {

  // Stimulus auto-parses a JSON-object -param value, so confirmWhen usually
  // arrives ALREADY parsed. Accept an object as-is; parse a string defensively
  // (a hand-built attr, or a non-Stimulus caller). A malformed string warns and
  // proceeds without a dialog (default-deny UX — the server is the real gate).
  let payload = confirmWhen
  if (typeof confirmWhen === "string") {
    try {
      payload = JSON.parse(confirmWhen)
    } catch {
      console.warn(`[phlex-reactive] malformed conditional confirm payload ${JSON.stringify(confirmWhen)} — skipped`)
      return null
    }
  }
  if (!payload || typeof payload !== "object") return null

  const { fields } = c.core.collectFields()
  const fieldValue = (name) => fields[name]

  let fires
  if (typeof payload.predicate === "string") {
    const fn = confirmPredicate(payload.predicate)
    if (!fn) {
      console.warn(`[phlex-reactive] confirm predicate "${payload.predicate}" is not registered — proceeding without a dialog (register it with setConfirmPredicate)`)
      return null
    }
    fires = !!fn(fields)
  } else {
    // Declarative: the DNF groups fold, identical to reactive_show — matches → fire.
    fires = anyOfAllsMatches(payload.groups?.any, fieldValue) === true
  }

  return fires ? payload.message : null
}
