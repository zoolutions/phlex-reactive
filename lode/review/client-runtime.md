# Review rules: the client runtime and the effect wire

Rules about `app/javascript/phlex/reactive/*.js` and the Ruby that compiles its payloads. Three of the five entries are *Not a bug* — the client's connect-time gate posture and its legacy arms draw a lot of reviewer fire, and the reasons they stay are worth keeping.

### A gate that hides a dead control must consider the component's own root, not only its descendants
- **Holds because:** a button-only component mixes `on_client(...)` onto `reactive_root`, so the ROOT can be the trigger. A gate that only walks `querySelectorAll` leaves a dead paste button visible in a browser with no Clipboard API — the one thing the gate exists to prevent. `#clipboardGateEnabled` checks `this.element.getAttribute("data-reactive-clipboard")` FIRST and falls through to the descendant scan, and `#syncClipboardTriggers` sets `this.element.hidden` on a marked root before iterating descendants. `#dirtyTrackingEnabled` is the precedent and reads the same way — root attribute first, then `querySelectorAll`.
- **Where:** `app/javascript/phlex/reactive/reactive_controller.js` — `#clipboardGateEnabled`, `#syncClipboardTriggers`, `#dirtyTrackingEnabled`
- **Proven by:** two bun regression tests for the root case (reveal and hide) in `spec/javascript/reactive_paste_op.test.js`
- **Origin:** PR #229

### A fire-and-forget effect run carries a per-element token it re-checks at every await point
- **Holds because:** the custom `legs` branch is invoked fire-and-forget for enter and update, and its final `classList.remove(...during, ...to)` always fires after its own settle. Two rapid updates on one element let the first run's cleanup strip classes the second just added, cutting the second animation short. `runLegsEffect` takes the per-element `__reactiveFxToken`, restart-clears an earlier run's leg classes up front, and checks the token at BOTH awaits — post-frame and post-settle — so the mid-flight from→to swap is guarded as well as the cleanup. A superseded exit run resolves early, which only lets Turbo's removal proceed sooner. The built-in className branch already had the token; the rule is that any new async choreography gets it too.
- **Where:** `app/javascript/phlex/reactive/reactive_controller.js#runLegsEffect`, `#runEnterOrUpdateEffect`
- **Proven by:** a bun test that freezes run 2 mid-choreography with manual frame control and proves the stale settle is a no-op
- **Origin:** PR #217

### All-blank effect legs raise; a single blank leg is legal
- **Holds because:** `LEG_KEYS.all? { legs.key?(it) }` checks key PRESENCE, so `{ during: nil, from: "opacity-0", to: "opacity-100" }` passed and compiled to an empty-string leg. All-blank is a dead effect with no classes to animate, and now raises — the same loud-failure contract `js_ops_json` applies to an empty ops chain. A SINGLE blank leg stays legal on purpose: an element whose own CSS carries the `transition` property needs no `during:` utilities, and `js.rb`'s `normalize_transition` already tolerates blank legs, so rejecting them here would fork one legs vocabulary into two. Client-side a blank leg splits to zero classes, a `classList` no-op, so neither choice crashes.
- **Where:** `lib/phlex/reactive/effects.rb#legs_wire`
- **Proven by:** `spec/phlex/reactive/effects_spec.rb:"rejects ALL-blank legs — a dead effect with no classes to animate"`, `:"tolerates a single blank leg (element-owned transitions need no during: utilities — the #186 contract)"`
- **Origin:** PR #217

### Nested arrays inside an op payload are frozen, not just the containers
- **Holds because:** the JS `OpsChain` mirrors the Ruby builder's immutability, and freezing only the outer containers left `classes` and the transition tuple mutable through `ops.ops` / `toJSON()` — so an already-constructed reducer chain could still be changed. `normalizeTransition` returns `Object.freeze([...])` and `classArgs` returns `classes: Object.freeze(list)`; every `add` returns `new OpsChain(Object.freeze([...this.ops, Object.freeze([name, Object.freeze(args)])]))`.
- **Where:** `app/javascript/phlex/reactive/compute.js` — `normalizeTransition`, `classArgs`, `OpsChain#add`
- **Proven by:** a deep-immutability bun unit test (`Object.isFrozen` down to `classes`/`transition`, plus a throwing `push`)
- **Origin:** PR #227

### Not a bug: feature gates are decided once at `connect()` and are not re-armed by a later morph
- **Holds because:** every sibling gate — dirty tracking, show bindings, filters, tags — decides once at connect. `turbo:morph-element` fires per morphed element and bubbles, so wiring the listener unconditionally would cost EVERY component a handler plus a scoped query per morphed element, to serve a trigger that is both conditionally rendered AND first introduced by an in-place morph. The documented contract is "render the paste trigger unconditionally"; a full replace re-connects and re-evaluates the gate, which covers the conditional case. The reviewer withdrew the finding on that reasoning.
- **Where:** `app/javascript/phlex/reactive/reactive_controller.js#connect` and the `#*Enabled` gates
- **Origin:** PR #229 (CodeRabbit, withdrawn)

### Not a bug: the legacy flat show-attribute arm is not extended with new predicates
- **Holds because:** `showBindingMatches` is the pre-0.10 flat-attribute arm (`data-reactive-show-equals` / `-not` / `-in` / numeric), kept only for deploy overlap and marked for deletion in its own comments. The 0.10 wire always emits the DNF payload, which routes through `showPredicateMatches` where the `len_*` predicates ARE evaluated — and the shared parity fixture proves both sides. No Ruby version ever emitted flat `len_*` attributes, so no real page can reach the legacy arm with a length predicate; a hand-built flat attribute warn-skips under the default-deny posture. Adding predicates to a scheduled-for-deletion arm that never carried them is dead code.
- **Where:** `app/javascript/phlex/reactive/reactive_controller.js` — `showBindingMatches` (legacy) vs `showPredicateMatches` (current); `spec/fixtures/show_predicate_vectors.json`
- **Origin:** PR #227 (CodeRabbit, withdrawn)

Related: [`../client-runtime/summary.md`](../client-runtime/summary.md), [`../component/summary.md`](../component/summary.md), [`testing.md`](testing.md).
