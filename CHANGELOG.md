# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]


### Fixed

- **`reply.pending` kept its settle handle under
  `enqueue_after_transaction_commit = true` (#254).** The handle was captured in
  `Phlex::Reactive::Settles#serialize`, which reads a thread-local that lives
  only for the duration of `reply.pending`'s enqueue block. Under Rails'
  `ActiveJob::Base.enqueue_after_transaction_commit = true` (the 7.2+
  recommended setting) `job.enqueue` is deferred to
  `ActiveRecord.after_all_transactions_commit`, and the endpoint runs every
  action inside a transaction — so `serialize` always ran AFTER the block had
  exited. The job serialized with no `phlex_reactive_settle` key,
  `reactive_settle` was a no-op, and the row sat shimmering until someone
  reloaded. The handle is now captured when the job INSTANCE is created
  (`perform_later` → `job_or_instantiate` → `new`), which is synchronous inside
  the block whether or not the enqueue itself is deferred; `serialize` prefers
  the captured handle and still falls back to the thread-local. Both the
  `job:`/`args:` sugar (narrowing per record, so failures stay attributable) and
  the block form are covered, and a retry re-enqueue keeps its handle. Jobs
  enqueued outside any `reply.pending` still carry nothing.


### Added

- **`bin/release` — the release front door, ported from pgbus.** Works out the
  next version (`patch` by default, `minor`, `major`, or an explicit `X.Y.Z`
  with an optional `v`), prints the commits since the last tag, and hands off
  to `rake release[X.Y.Z]` after a y/N confirm. `list` and `--dry-run` are
  read-only. It refuses to run off anything but a clean, up-to-date `main` —
  the rake task pushes `origin main`, so starting anywhere else either fails
  the push or ships whatever local commits happen to be sitting there — and
  refuses an existing tag unless `--force` (which maps to `release[X.Y.Z,force]`).
  It also warns when `version.rb` and the newest `v*` tag disagree.

- **Async-action lifecycle: `reply.pending` + `reactive_settle` (#248).** An
  action that *enqueues* work can now reply truthfully. The endpoint renders the
  reply inside the action's transaction while the queue publishes on commit, so
  any `reply.morph` after an enqueue is guaranteed to draw the pre-job world —
  rows still present, buttons still live — beside the "Queued 177" flash the
  same reply emitted. Apps worked around it with a `queued:` kwarg threaded into
  every row component plus a second render branch; ~60 lines per screen, and the
  page still never learned the outcome.

  `reply.pending(records, in: :collection, job:, args:)` — or the block form,
  `reply.pending(records, in: :collection) { MyService.call(...) }`, which every
  ActiveJob enqueued inside captures — marks the targets with
  `data-reactive-pending` + `aria-busy` (style it in one CSS rule), opens ONE
  shared durable subscription anchored on the container, and hands the
  fulfilment to your job. The job includes `Phlex::Reactive::Settles` and calls
  `reactive_settle { |s| s.remove(record) }` (also `replace` / `append` /
  `prepend` / `move(from:, to:)` / `count` / `flash` / `js` / `streams!`), which
  emits the row **plus** the count companion **plus** the 0↔1 empty-state
  toggle. `peers: true` broadcasts the same delta to the container's record
  stream for a second operator watching the batch.

  The handle rides **ActiveJob metadata**, so `perform`'s arity is untouched and
  every other caller of the same job — a nightly sweep, a webhook — runs
  unchanged with `reactive_settle` as a no-op. The `job:`/`args:` form narrows
  each job's handle to its own record, so a job that raises clears exactly that
  row's markers before re-raising for the retry policy. No client changes: the
  markers ride the existing `reactive:js` op lane and the subscription is the
  `reactive:defer` push-lane wire from #165.

- **`Phlex::Reactive::Collections` — the collection bookkeeping is now a public
  module (#248).** The count companion and the 0↔1 empty-state boundary used to
  live in `Response`'s privates, reachable only from `reply.*`, so a job or a
  broadcast had to re-derive them by hand and got the boundary subtly wrong.
  `Response.build_collection_*` now delegates, and the settle and broadcast
  paths read the same `count_refresh` / `empty_toggle` decisions — they cannot
  drift. No behavior change for existing `reply.append` / `reply.remove` calls,
  except that each delta now resolves the `size:` proc **once** instead of twice
  (one fewer query per add/remove, and the count companion can no longer
  disagree with the empty-state toggle it ships beside when a concurrent write
  lands between the two reads).

- **`Container.broadcast_collection_to(*keys, container:, in:, append:/prepend:/remove:)`
  (#248).** The broadcast-side counterpart of `reply.append` / `reply.remove`:
  the row **plus** the count companion **plus** the empty-state toggle, instead
  of the bare row `broadcast_to(append:)` emits. `coalesce:` applies to the
  aggregate streams only (idempotent replaces of stable targets), so a 177-row
  fan-out collapses to a handful of count refreshes; the row stream is never
  coalesced. Needs pgbus with zoolutions/pgbus#465 — a thread-local an older
  pgbus simply ignores, so it degrades to "chattier, equally correct" rather
  than breaking.

- **`Phlex::Reactive.settle_coalesce_window_ms` (50) and `.settle_capable?`
  (#248).** The window governs the aggregate (count / empty-state) streams on
  the peers path. `settle_capable?` reports whether `reply.pending` has a lane
  at all; without one it degrades to a plain enqueue (no markers, no lie) with a
  one-time warning. There is deliberately no `settle_token_ttl` — a settle has
  no pull lane for a token to govern.

- **`reactive_persist` drafts rich editors (#241).** A named `lexxy-editor`,
  `trix-editor` or bare `[contenteditable]` inside a `reactive_persist` root is
  now drafted and restored through its **own** value surface — the editor's
  `value` getter/setter (its serialized HTML, replayed through the editor's own
  sanitizing import: Trix `HTMLParser`, Lexxy `$generateNodesFromDOM` +
  sanitizer), a bare contenteditable's `textContent` — never `innerHTML`. The
  name resolves from the element's `name` attribute or, for Trix in the Rails
  `rich_text_area` shape, from the `input=`-paired hidden input (never a
  separate key). `restore: :blank` asks the editor whether it is empty (Lexxy
  `isEmpty`, Trix `editor.getDocument().isEmpty()`, an exact-string fallback),
  so an attachment-only server body is never overwritten. An editor not yet
  upgraded at connect (Trix defines its elements in a `setTimeout`; a lazily
  imported Lexxy) is restored once `customElements.whenDefined` resolves; a
  throwing setter never escapes `connect()` (one `console.info` under
  `Phlex::Reactive.debug`). The editors' own `lexxy:change` / `trix-change`
  events drive the debounced write (neither lets its native `input` bubble),
  and their toolbar chrome (Lexxy's code-language select and link `href`
  input, Trix's `trix-toolbar`) is never drafted. `fields:`,
  `reactive_persist_skip` (on the editor element) and nested-root ownership
  apply unchanged. The dummy vendors the
  real Trix 2.1.19 and Lexxy 0.9.31 and the browser suite drives both under
  Puma and Falcon.

- **`reactive_persist` — client-only localStorage drafts (#239).** "Don't make
  me start over": spread `reactive_persist(key:, ttl: 7.days)` on a root and
  the generic controller keeps a `localStorage` draft of every **owned**
  control — a debounced write on `input`, immediate on `change`, flushed on
  disconnect — and restores it on the next connect, **first** among the
  client bindings so `reactive_show` / `reactive_on_complete` (armed, never
  fired) / `reactive_filter` / a compute root read the restored values on
  first paint with no synthetic events. A draft lands only in controls the
  server rendered blank (`restore: :always` lets it win); a morph is never
  re-restored. Cleared by a successful `turbo:submit-end` of the containing
  form, `ttl` expiry, or the new actor-only `js.persist_clear` op;
  `js.persist_state(step: 2)` merges a flat state bag into the draft (restored
  as `data-reactive-persist-state` + the `reactive:persist-restored` event).
  `hidden`/`file`/`password`/`submit` controls, `reactive_persist_skip`
  markers and nested roots are never persisted; `fields:` narrows the set. Storage failures are silent (a `console.info` under
  `Phlex::Reactive.debug`). Works from `ClientBindings` (no token, no POST).

- **Dev-mode warning when a client op resolves zero targets (#237).** A client
  op that matches nothing is indistinguishable from a working no-op, and the
  three documented scoping traps — the nested-root ownership filter, a selector
  that matches the component's own root (root-scoped resolution never includes
  the root itself), and the op stream's default target scope — all present
  exactly that way. Now `verbose_errors` (on by default in dev/test) reaches
  the client as `data-reactive-verbose="true"` on reactive roots and on
  server-emitted `reactive:js` streams, and under that gate (or full
  `debug` mode) the interpreter `console.warn`s once per unique
  (op, selector, scope) naming the op, the selector, and the scoping root —
  plus the documented escape (`to: :root` / `global: true`) as a hint when the
  element exists in the DOM but sits outside the op's scope. Covers `on_client`
  ops, reducer `$ops`, `reply…js(...)` / `broadcast_js_to` streams (including a
  stream whose `target` root id has left the DOM), and busy/optimistic hint
  targets. Production (flag off) renders no attribute and stays byte-identical
  and silent; resolution behavior itself is unchanged everywhere.

- **`js.paste_into(selector)` — the clipboard-source trigger (#228).** A field
  whose real `<input>` is visually hidden (an OTP cell UI painted by a
  `reactive_compute` reducer) has no mouse-reachable paste path: right-click →
  Paste targets the decorative cells, never the off-screen input. One declared
  line — `button(hidden: true, **on_client(:click, js.paste_into("[name=code]")))
  { "Paste code" }` — replaces the bespoke Stimulus controller:
  - **The op** (the one async, value-reading member of the vocabulary): on the
    user's gesture it starts `navigator.clipboard.readText()` fire-and-forget
    (the browser's own permission UX — Chromium prompts, Safari shows its
    paste pill) and, when the read resolves, feeds the text through the
    **normal `input` pipeline** — set `.value`,
    dispatch a bubbling `input` (reducers / `reactive_show` /
    `reactive_on_complete` run exactly as if typed), then focus the field so a
    partial paste continues from the caret. A denied/dismissed read, empty
    text, or a missing API is a **silent no-op**; the op is fire-and-forget,
    so chained siblings never wait.
  - **Availability gating**: `on_client` marks a paste trigger with
    `data-reactive-clipboard`; on connect (and every `turbo:morph-element`)
    the controller sets `hidden = !available` on owned markers. Author the
    trigger `hidden` and it is revealed only where the Async Clipboard API
    exists — a dead button never shows in insecure contexts or webviews.
  - **Actor-only, default-deny**: `paste_into` joins `focus`/`focus_first`/
    `submit` in `BROADCAST_REFUSED_OPS` — `broadcast_to(js:)` raises
    (a broadcast that reads every subscriber's clipboard would be hostile);
    `reply.js` and gesture paths remain allowed.
  - Dummy flagship: the `VerificationCodeComponent` OTP field gains the
    hidden "Paste code" trigger — paste drives the otp reducer's normalize +
    `$ops` auto-submit end to end, with a real-browser system spec covering
    reveal-on-connect, dirty-paste auto-commit, partial-paste focus, and the
    denied-read no-op.

- **Reducer-emitted client ops (`$ops`), a `submit` op, and declarative
  `reactive_on_complete` (#226).** The "normalize on input, commit when
  complete" field (a one-time-code entry being the canonical case) is now
  declarable end to end, single- or multi-input, with no bespoke controller:
  - **`js.submit(to = :root)`** joins the op vocabulary: requestSubmit the
    target's own form (the target itself when it *is* a form, `input.form`
    for a control, else `closest("form")`). A real cancelable `submit` event
    fires, so it composes with native/Turbo forms AND
    `on(:save, event: "submit")` interception —
    `select(**on_client(:change, js.submit("form")))` is the one-line general
    autosubmit. **Actor-only like focus**: refused in `broadcast_to(js:)`
    (allowed in `reply.js`); `on_client(:submit, js.submit)` raises (it would
    re-fire itself).
  - **The reserved `$ops` reducer output**: a `reactive_compute` reducer may
    return `$ops` holding an op chain — built with the new immutable `ops`
    builder exported from `phlex/reactive/compute` (verbs mirror the wire op
    names) or a raw `[[op, args], …]` list — run through the same frozen
    client-op whitelist as a final phase after the write set settles.
    **Rising-edge, keyed on chain content, event-gated**: an identical chain
    never re-fires (a capped 7th keystroke can't re-submit), a changed chain
    fires again (per-digit focus advance across split boxes), and the
    connect/morph seed pass arms without firing (a validation-error re-render
    with a complete value never self-submits).
  - **`{ length: … }` in the ONE conditions language**: exact
    (`{ length: 6 }`) or Integer-Range length predicates for
    `reactive_show` / `reactive_show_targets` / `reactive_on_complete`,
    counted in **codepoints** on both sides (Ruby `String#length`, client
    `[...value].length`) — the shared parity fixture gains a multibyte proof
    vector.
  - **`reactive_on_complete`** — the zero-JavaScript declarative twin: the
    same `if:`/`if_any:`/`unless:` kwargs as `reactive_show` plus `run:` (a
    `js` chain, now buildable at class level, or an allowlist-checked raw
    list), emitted as one root attr and evaluated by the generic controller
    with the same rising-edge/arming semantics as `$ops`.
    `reactive_on_complete if: { code: { length: 6 } },
    run: js.dispatch("code:complete")` + `on(:verify, event: "code:complete")`
    is a complete auto-committing code field with no reducer at all.
  - Dummy flagships: `VerificationCodeComponent` (single input + `$ops`
    submit), `SplitCodeComponent` (six boxes: paste redistribution,
    reducer-driven focus advance, hidden joined-code output),
    `CodeCompleteComponent` (declarative, zero JS), and the
    `AutosubmitFilterComponent` select-driven GET filter — each with a
    real-browser system spec.

- **Instance-dynamic wire names — keyword escape hatches on the
  field-compiling helpers (#224).** A form builder's wire name is computed per
  instance (`user[tags]`), which the class-level `reactive_scope` compile can't
  express — the gap that forced phlex-forms' `tag_field` draft
  (mhenrixon/phlex-forms#6) onto raw data attrs. Every helper that compiles a
  field name now takes a verbatim keyword escape hatch (never re-scoped,
  validated at render, mutually exclusive with the blessed field form):
  `reactive_tags(name: "user[tags]")`, `reactive_filter(input: "#tags_query")`
  (a raw CSS selector — the deliberately **name-less** query input inside a
  real form, targeted by id, so it can never submit a stray param),
  `nested_field_name(:items, :qty, scope: "order")` (a per-call parent prefix
  that wins over `reactive_scope`), and
  `reactive_nested_list(:items, as: :json, name: "order[items]")` (the hidden
  JSON sync field, JSON mode only). Server-side sugar only — the client already
  resolves these attributes as arbitrary root-scoped selectors; the shipped
  wire for existing calls is byte-identical. Note: `reactive_filter(input:)`
  deliberately re-blesses the kwarg removed in #186 — the field form stays the
  blessed default, and a pre-0.10 `input:`/`option:` call shape is valid again
  with identical semantics instead of raising the removal error.

- **Project board — the kanban flagship demo (#216).** A live three-lane board
  on the docs site (`/docs/example-project-board`, `/demos/project-board`)
  composing the toolkit end to end: each card is its own nested reactive root
  (record + signed style state) whose move is ONE reply — the row's remove
  (its exit effect animates before the element leaves), a fresh-token append
  into the new lane (wearing its enter effect), and a `reactive:js` text-op
  stream repainting all three count badges — with the same delta broadcast to
  peers, actor echo excluded. Inline rename morphs in place, archive is
  confirm-gated + optimistic, per-lane composers flash on a blank title, and
  the effect-style picker (including `random`) rides signed state to drive
  per-call `effect:` overrides. Peer count badges stay live everywhere via
  `broadcast_to(js:)` — closing the stale-badge gap the team-inbox flagship
  documents — and empty lanes are pure CSS `:empty`, so the 0↔1 boundary
  needs no bookkeeping on either delivery path. Docs-app only; no gem code
  changes.

- **Reactive effects — animate enter/exit/update on every stream render (#215).**
  Opt-in at three levels, most specific wins: `Phlex::Reactive.effects = true`
  (or a `{ enter:/exit:/update: }` hash) is the global switch AND the app-wide
  default set; `reactive_effects enter: :slide, update: false` refines per
  component (`false` opts out entirely; declaring on a component also works
  standalone with no global switch); `effect:` on every stream builder, reply
  verb, and `broadcast_to` overrides one stream (`effect: false` suppresses a
  declared effect for that call). Five built-ins ship as an engine stylesheet —
  `stylesheet_link_tag "phlex/reactive/effects"` — fade/slide/scale/highlight/
  shake, all inside `prefers-reduced-motion: no-preference` and tunable via
  `--reactive-fx-*` custom properties; `:random` picks a built-in per
  application; custom effects take the `{ during:, from:, to: }` class-legs
  vocabulary (issue #186), Tailwind-friendly and stylesheet-free. On the wire
  the resolved hooks ride the component root as `data-reactive-effect-<hook>`
  attributes (omitted entirely when off — byte-identical to previous releases)
  and per-call overrides ride the `<turbo-stream>` element itself; ONE
  document-level `turbo:before-stream-render` interceptor animates replies AND
  broadcasts identically on Action Cable and pgbus. `remove` is special: the
  exit animation runs BEFORE the element leaves the DOM, awaited via
  `animationend`/`transitionend` with a computed-duration fallback hard-capped
  at 1s — and a zero computed duration (no effects CSS loaded) skips the wait
  entirely, so a missing stylesheet can never freeze a removal. Unknown names
  raise at class load server-side and warn-and-skip client-side (two-sided
  default-deny). Zero additional allocations per render with effects on (the
  resolved fragment is a per-class memo keyed on the config + registry
  generations); the render/token hot paths hold flat with effects off.

- **Confirm on the draft-row remove — `reactive_nested_remove(confirm:)` (#218).**
  `reactive_nested_remove` now accepts the SAME `confirm:` the other triggers
  (`on`/`on_client`) do — a static message String, or the conditional Hash form
  (`{ when: …, message: }` / `{ predicate: …, message: }`, #179) — routed through
  the shared `apply_confirm!` and gated client-side behind the same overridable
  `confirmResolver` (the styled-modal seam, #52/#55/#178). On accept it does the
  existing remove (a draft row leaves the DOM; a persisted row is `_destroy`-marked
  + hidden) and the existing JSON/attributes re-sync; on cancel, nothing. Per-row
  messages come for free — the confirm is a per-render string. Works in BOTH wire
  modes (`:attributes` and `as: :json`). No confirm: → the immediate-remove fast
  path, unchanged.

- **Fill-then-add for draft nested rows — `reactive_nested_add(:assoc, from:, clear:)` (#208).**
  The draft-rows primitive's add is *inline-edit* — it clones the template and
  focuses the new row's first field, so you type INTO the row. A common
  alternative puts the add controls OUTSIDE the row (a preset `<select>`, a
  typeahead, plain inputs) and "Add" **snapshots** those values into a new row,
  then clears them for the next entry. `from: { row_field => "#source-selector" }`
  seeds each cloned-row field from its source control's current value (matching
  the field by the same trailing-bracket-segment key inference JSON mode uses),
  keeps focus on the sources rather than stealing it into the row, and `clear:
  true` resets the sources (each via the set-value + dispatch contract, so dirty
  tracking and compute observe the reset). `from:` values are raw CSS selectors
  resolved within the reactive root (#15 ownership); an unresolved source or an
  unmatched row-field key is silently skipped (the row still adds). It composes
  with BOTH wire modes: the seeded values ride the renumbered `_attributes` names
  on submit (`:attributes`) and the end-of-add JSON sync serializes them
  (`as: :json`), with no extra wiring. The no-`from:` inline-edit default is
  unchanged. See the "Draft rows for a new parent" README section and the
  `/docs/example-draft-rows` page.

- **Multi-field cross-root targets — `reactive_show_targets` speaks the full
  conditions language (#209).** A `"#id"` KEY now takes an `if:`/`if_any:`/
  `unless:` conditions Hash, so an OUTSIDE element can show/hide from a
  COMBINATION of owned fields — `reactive_show_targets("#trade-warning" =>
  { if: { type: "trade", price: ..0 } })` — the last case that forced a
  bespoke two-field JS listener on otherwise-declarative forms. The client
  folds the target's DNF payload with the SAME per-term owned-field reads as
  an in-root `reactive_show` (missing owned field reads blank, fail-closed);
  a target whose referenced fields are ALL unowned is left alone (the
  single-field skip, generalized). Target-keyed and field-keyed entries mix
  in the ONE call per root (a field name may never start with `#`, so the
  key routes unambiguously); existing field-keyed calls emit a byte-identical
  wire. Declare-time validation stays loud: a bare value, unknown keys, or an
  empty conditions Hash under a `"#id"` key raises a guided `ArgumentError`.

- **JSON mode for draft nested rows — `reactive_nested_list(:assoc, as: :json)` (#208).**
  The draft-rows primitive (#208) posts standard Rails
  `accepts_nested_attributes_for` names. But many apps persist a "new parent +
  child rows" form by serializing the rows into ONE hidden field and
  `JSON.parse`-ing it in the controller — adopting the primitive meant rewiring
  that persistence path. `as: :json` removes the choice: the list keeps the same
  `<template>` row, `nested_field_name`, and add/remove triggers, but the generic
  controller now mirrors the surviving rows into a single hidden field as a JSON
  array on every add / remove / keystroke (the set-value + dispatch contract, so
  dirty tracking and compute still see it), inferring each JSON key from the
  trailing bracket segment of a row input's name
  (`order[line_items_attributes][3][quantity]` → `"quantity"`). A removed row
  leaves the array (an absent row IS the removal — JSON has no `_destroy`
  marker). The default (`:attributes`) is unchanged, so existing draft forms are
  byte-identical. See the "Draft rows for a new parent" README section and the
  `/docs/example-draft-rows` page.

- **Turnkey APM adapters — `Phlex::Reactive.apm = :appsignal` (#207).** The gem
  already emits `*.phlex_reactive` `ActiveSupport::Notifications` events (#107), but
  every reactive action still POSTs to the same endpoint, so an APM rolled all
  reactive traffic into one blurry `ActionsController#create` transaction and an
  action-body crash surfaced as an anonymous 500. One config line closes both gaps:
  - **`Phlex::Reactive.apm = :appsignal` (or `:sentry`, `:datadog`, or a custom
    object)** names each action as its own `Component#action` transaction/span in the
    APM, tagged with the component, action, and outcome. The vendor SDK is
    **runtime-detected** (`defined?(::Appsignal)` …) — never a gemspec dependency, the
    same optionality invariant as pgbus — so a set-but-absent SDK logs one warning and
    no-ops. A custom object need only respond to `record_action(payload, duration_ms)`
    and `record_error(error, payload)`.
  - **Action-body errors are reported with context.** A previously-uncaught error from
    an action body (a genuine 500, not a registered 4xx) is now OBSERVED at the
    endpoint: the `action.phlex_reactive` event is tagged `outcome: :error` (filling the
    #107 nil-outcome gap), the exception is reported to the APM adapter AND every
    registered `Phlex::Reactive.on_action_error { |error, ctx| … }` hook WITH the
    name-only `{ component:, action: }` context, the `error_flash` renders so the actor
    sees a flash on a crash (500s now flow through the same path the 4xx errors used) —
    and THEN the error is **re-raised unchanged**, so Rails' own error reporting and the
    app's middleware fire exactly as before. Each reporter is isolated: a broken reporter
    (or a raising `error_flash` lambda) can never turn one 500 into a different 500 or
    swallow the original. The status never changes; the existing 4xx rescues, their
    statuses, and their outcomes (`invalid_token`/`denied_undeclared`/`not_found`/
    `unauthorized`/`unverified`) are untouched. Payloads and error tags stay name-only —
    never the token, params, or state.

- **Draft nested-attribute rows — the "new parent + child rows" form (#208).**
  A collection whose PARENT isn't persisted yet (a new order accumulating line
  items) can't be a reactive collection — an unsaved parent has no gid to sign.
  The pre-save window is now a client-side primitive, the `reactive_tags`
  posture: `reactive_nested_list(:assoc)` / `reactive_nested_template(:assoc)`
  mark the container + the server-owned `<template>` holding ONE row's markup;
  `reactive_nested_add(:assoc)` clones it, swapping every `NEW_ROW` placeholder
  in the clone's `name`/`id`/`for` for a fresh unique index (clock-seeded
  monotonic — server-rendered `0..n` and same-millisecond double clicks can't
  collide) and focusing the new row's first field; `reactive_nested_remove`
  deletes a draft row from the DOM, or `_destroy`-marks + hides a row carrying
  a hidden `[_destroy]` input (an edit form's persisted row) so Rails destroys
  it on save. `nested_field_name(:assoc, :field, index:)` builds the
  scope-aware Rails wire name (`order[line_items_attributes][i][quantity]`).
  Zero round trips, no token (works in a `ClientBindings` component); the REAL
  form submit reconciles parent + rows in ONE request via
  `accepts_nested_attributes_for`. Several collections can share a root
  (association-keyed); the row markup is authored ONCE and serves the template,
  server-rendered edit rows, and the persisted `reactive_collection` flow.

- **`reactive_tags` — the tag-chip input primitive (#203).** The composed
  combobox/tags widget (preload suggestions, type to narrow, Enter/click to add,
  remove chips) with zero bespoke JavaScript and zero round trips. The value is
  FORM state in a hidden **comma-joined** field the root names
  (`reactive_tags(:tags)`, scope-aware like `reactive_filter`); the chip list is
  a client projection of that field, rebuilt per change by cloning a
  server-owned `<template>` chip (`textContent` writes only — never
  `innerHTML`). Three client-only triggers: `reactive_tags_add` (Enter adds the
  typed text — composed after `reactive_listnav`, a highlighted option wins and
  Enter never submits the enclosing form), `reactive_tags_option(tag)` (click a
  suggestion to add its declared tag), `reactive_tags_remove(tag)` (a chip's
  remove button; no arg inside the template — the client fills it per chip).
  Tags dedupe case-insensitively; a comma-separated paste splits; a declared tag
  containing a comma raises at render. Selected suggestions hide + mark
  `data-reactive-tags-selected` (`reactive_filter` keeps them hidden through
  re-filters) and resurface on removal; a morph re-projects the chips from the
  field's server value; every write dispatches a real `input` event on the
  hidden field so `reactive_dirty`/`reactive_show`/`reactive_compute` see it.
  Works in a token-less `ClientBindings` component — nothing here POSTs.

- **A global reactive-activity signal — the analogue of Turbo's progress bar (#201).**
  The client now maintains a document-level count of in-flight reactive operations
  across ALL roots — incremented when a dispatch round trip or a deferred render
  starts, decremented when it settles — and exposes it two ways:
  - a marker on `<html>`: `data-reactive-active` is present while the count is `> 0`,
    so CSS can drive a global spinner and code (or a test) can read "is the reactive
    layer settling?" without knowing about any individual root;
  - events on `document`: `reactive:busy` fires on the `0 → >0` edge and
    `reactive:idle` on the `>0 → 0` edge (edges only, each carrying `{ count }`), so
    an app can flip a spinner or gate an "unsaved changes" guard globally.

  Purely additive — every per-root marker/event (`data-reactive-busy`, `aria-busy`,
  `data-reactive-defer-pending`) is unchanged. A distinct attribute name
  (`data-reactive-active`, not the per-root `data-reactive-busy`) keeps the
  document-level signal unambiguous. `compute_seed` is not counted: `recompute()` is
  synchronous, so a seed settles inline with no async window to await.

- **`Phlex::Reactive::TestHelpers::System` — system/browser test helpers built on the
  activity signal (#201).** Opt-in and loaded only when Capybara is present (the same
  optional-require gate as the RSpec matchers), so it stays entirely out of the
  runtime path. Mix it into system examples:

  ```ruby
  RSpec.configure do |c|
    c.include Phlex::Reactive::TestHelpers::System, type: :system
  end
  ```

  - `wait_for_reactive` — block until the layer is idle (every round trip AND deferred
    render settled, the `<html>` marker cleared). The system-test twin of
    `wait_for_turbo`, which watches the Turbo progress bar, not a reactive morph/seed.
  - `have_reactive_value(id, value)` / `have_reactive_text(id, value)` — assert a field
    or a mirror/recap node by RE-RESOLVING it by id every poll, so a `reactive_compute`
    re-seed or a morph that replaces the node after the action returns can never raise
    `StaleReferenceError` or read a transient blank — the matcher waits for the value
    to settle.

### Fixed

- **`rake release` bumps the pin in every tracked lockfile (#247, #253).** Since
  #246 the gem root's `Gemfile.lock` is committed alongside `docs/Gemfile.lock`,
  and both pin `phlex-reactive` by local path — so a version bump that left them
  alone shipped a stale lockfile, and the Release workflow's frozen
  `bundle install` refused it (v0.13.0's first attempt).

  The task now bumps that pin **with a text edit**, not `bundle lock`. #247's
  first cut used `bundle lock --local`, which is a full re-resolve — and a
  re-resolve trips over constraints that have nothing to do with this gem:
  `docs/Gemfile.lock` declares Linux platforms for the Kamal deploy, and
  resolving `thruster` for those against a Mac's installed gems fails ("Could
  not find gems matching 'thruster' valid for all resolution platforms"), which
  aborted v0.13.1's first attempt mid-release with `version.rb` already bumped.
  A re-resolve also silently folds unrelated dependency drift into the release
  commit the moment a Gemfile is out of sync with its lock. The only line a
  version bump changes is the path-gem pin, so the task edits exactly that (the
  `PATH` spec + the `CHECKSUMS` entry) in place — deterministic on any machine,
  no network, no installed gems, the same 2-line diff bundler produced. A
  lockfile that names no pin at all now **aborts** the release rather than
  reporting itself already current — and that check runs in a PREFLIGHT, before
  the task does anything destructive or irreversible: before the `force`
  cleanup that deletes the GitHub release and its tag, and before `version.rb`
  or any lockfile is written. So an abort leaves the release intact and the tree
  clean, rather than a deleted release or a half-bumped tree the clean-tree
  guard would then block on retry.
  pgbus's release task made the same call after the same failure.

- **`Component::Action` renamed `ActionDefinition` — it shadowed a host kit
  component named `Action` under dev autoloading (#233).** The mixin sits in
  every reactive component's ancestry, so its bare `Action` constant satisfied
  Phlex::Kit's LazyLoader `const_get` check with the wrong class: the kit's
  real `Action` component never autoloaded and the call fell through to
  `NoMethodError` — intermittently (any unrelated load of the kit class masks
  it until the next reload) and only under lazy autoloading, so an
  eager-loaded test suite stays green. The rename matches its siblings
  (`ComputeDefinition`, `OnCompleteDefinition`, `CollectionDefinition`) and
  removes the constant entirely — **deliberately no alias**, since any
  `Action` constant in the ancestry re-creates the shadowing. Breaking only
  for code referencing the internal
  `Phlex::Reactive::Component::Action` Data class directly; the `action :name`
  DSL and `reactive_actions` registry are unchanged. A regression spec guards
  the whole component ancestry against `:Action` coming back.

- **Multipart path corrupted/dropped fields with Rails-bracketed names (#231).**
  `#buildFormData` wrapped every collected field/file name verbatim as
  `params[<name>]`, so `blog_post[summary]` went out as the Rack-unparseable
  `params[blog_post[summary]]` — the scalar arrived as `{"]" => value}` (and a
  writer stringified that hash into the record, with a 200), and a `:file` under
  a bracketed name (`blog_post[image]`) never reached its schema key (silent
  drop). It only fired when a file input was populated — the JSON path expands
  the same names server-side — which is why flat-named forms never caught it.
  The client now bracket-expands the field **name** into wire segments
  (`params[blog_post][summary]`, `params[blog_post][image]`, and
  `params[photos][]` for a `multiple` picker named `photos[]`), mirroring the
  server's `bracket_path` exactly, so a multipart body and a JSON body coerce
  identically for the same fields. Flat names are byte-identical to before.

- **Reply-rendered components now generate absolute URLs with the REQUESTING
  host, not the process default (#232).** Actor replies (`reply.replace`,
  `reply.streams(...)`, the implicit replace) render through the memoized
  off-request view context, whose `url_options` were process defaults — so any
  absolute URL helper (`image_tag` on an Active Storage attachment being the
  everyday case) rendered the wrong host on a multi-host app: a broken image
  after every save, healed by the next full page load. The action endpoint now
  threads the request's protocol/host/port into the reply render (the
  `ActiveStorage::SetCurrent` move) via a thread-local the memoized context
  merges per call — the context is never rebuilt, so the render memoization
  win is untouched (allocations byte-identical, throughput flat within noise).
  The defer **pull** endpoint gets the same treatment (it is an actor request).
  **Broadcasts are unchanged by design** — there is no request and subscribers
  can be on different hosts, so a broadcast fired *inside* an action explicitly
  clears the actor's url_options around its render; "URLs in broadcast-rendered
  components must be host-relative" is now documented in the Broadcasting guide.

- **`rake bench` ran the removed `broadcast_replace_to` API and exited 1.**
  `benchmark/micro/broadcast.rb` migrated to the #185 spellings
  (`broadcast_to(*key, replace:)` / `broadcast_to(each:, replace:)`); the
  transport double is unchanged.

- **`reactive_nested_remove(confirm:)` now interpolates `%{field}` on client-added
  rows (#222).** A row added in the browser via `reactive_nested_add` is a
  `cloneNode` of the `<template>`, and the clone path (`#renumberNestedRow` /
  `#seedNestedRow`) never rewrote the confirm attribute — so a per-row confirm
  froze to the template's value-less string on every added row (the exact rows
  the primitive exists for). The client now resolves `%{field}` placeholders in
  the confirm message from **that row's live field values** at click time (keyed
  by the same trailing-bracket inference `as: :json` uses), so
  `confirm: "Delete '%{name}'?"` on the template shows `Delete 'Widget'?` on the
  added row — reflecting a later edit too (resolved on remove, not on clone). An
  unresolved `%{key}` is left as its literal text (debuggable, never a silent
  blank); the placeholder works in the conditional Hash's `message:` as well.
  Server-rendered rows already interpolate server-side, so their finished strings
  are unaffected. **Also (superset of the issue's proposal 3):** `confirmResolver`
  now receives an optional second argument — a context object, always `{ el }`
  (the trigger), plus `{ row, fields }` on a `reactive_nested_remove` — so a
  themed-dialog override can build row-specific messages programmatically. The
  arg is additive: a one-parameter resolver (and `window.confirm`) is unchanged.

- **A draft (unsaved-parent) token can now round-trip real server actions (#208).**
  `Component::Identity` already signed a gid-less `{c, state}` token for an
  unpersisted (or nil) record, but `from_identity` still `fetch`ed the absent
  `gid` — the FIRST action against a draft crashed with an uncaught `KeyError`
  (500). It now rebuilds through the record kwarg's **initialize default**
  (e.g. `def initialize(order: Order.new, …)`), with the declared
  `reactive_state` riding the token as before; a component whose initialize
  REQUIRES the record kwarg raises a guided `Phlex::Reactive::Error` naming the
  fix instead of a bare missing-keyword `ArgumentError`.

- **`have_reactive_value` now reads the field's `.value` property, so it can verify a
  reducer-set disabled/computed field (#204).** The matcher (added in #201) delegated to
  Capybara's `have_field(with:)`, which matches the value **attribute** — but a
  `reactive_compute` reducer paints a computed output by setting its JS `.value`
  **property** (`el.value = …`), and for a **disabled / read-only** output the attribute
  never reflects that. So the matcher read `""` and failed on exactly the fields it was
  built for. It now re-resolves the field by id **or name** each poll and asserts the live
  `.value` property (via `evaluate_script`), covering enabled AND disabled/computed fields
  while keeping the morph-immunity. `have_reactive_text` (textContent) was unaffected.

- **A freshly-rendered `reactive_compute` root now self-seeds its derived fields on connect (#199).**
  Before, a compute root computed nothing until the first user `input` — a fresh render
  (or a server validation-error re-render that replaced the body) left every derived
  output and cross-root `mirror:` node blank until you typed. Apps worked around it by
  dispatching a synthetic seed `input` on connect, but the compute root is a distinct
  Stimulus controller that may connect a frame later, so the seed raced its own wiring —
  the reported symptom being a PARTIAL apply (an early output painted; a later output
  and the mirror stayed blank). Now `connect()` runs ONE full `recompute()` after the
  controller is fully connected, so the whole single-pass write set (batch outputs →
  paint text sinks + cross-root mirrors → dispatch) runs synchronously and every
  declared output, text sink, and mirror paints from a single reducer result — no user
  interaction, no round trip. It re-seeds on `turbo:morph-element` (the show/filter/dirty
  precedent) and is idempotent (change-guarded writes make a re-seed a no-op, so an app
  still dispatching a synthetic input is harmless). The seed is gated on a new
  `data-reactive-compute-seed` marker emitted by `reactive_root(compute:)`; a non-compute
  root pays one attribute read and never seeds. The seed passes no event, so
  `meta.changed` is `null` — the correct "no field edited yet" semantics, so a convergent
  reducer's default branch computes the full settled set.

- **Scoped form fields no longer silently drop their params — the #67 footgun is fixed (#184).**
  Under `reactive_scope`, `reactive_field(:date)` now emits the scoped wire name
  (`name="invoice[date]"`), so the POST arrives bracketed — and the endpoint unwraps
  exactly ONE scope level before schema matching, so a FLAT schema
  (`params: { date: :string }`) matches. Previously a scoped field either POSTed a bare
  name (misaligned with the `reactive_show`/`reactive_compute` resolvers, which already
  query `[name="scope[x]"]`) or forced a hand-written bracketed name + a hand-nested
  schema that Rails' bracket-expansion silently dropped. The client's `meta.changed`
  resolver (`#changedComputeField`) is now scope-aware too, so a scoped compute
  component's reducer still sees the bare declared name.

- **`reactive_compute` output order no longer silently corrupts values (#183).**
  Each output write used to dispatch an `input` event **mid-loop**, re-entering the
  reducer synchronously from a **half-written DOM** — so a wrong `outputs:` order
  could commit wrong values (a real money-corruption class), settling only if the
  reducer was convergent in exactly the declared order. The client now runs the
  reducer **once** from one pre-write input snapshot, writes all changed outputs as
  a **batch**, paints text/mirror sinks from the settled values, then dispatches the
  `input` events — each self-marked so the root skips re-running its own reducer
  while other listeners (chained repaint, dirty tracking, `reactive_show`, sibling
  roots) still fire. Declared output order is no longer semantics. Covered by a JS
  order-independence test (declare outputs in the historically-wrong order — values
  stay correct) and a self-re-entry-suppression test.

### Changed

- **Client build toolchain: bun 1.3.14 → 1.4.0.** `.bun-version`, the root `engines.bun`
  floor, and the docs `packageManager` pin all move together. The shipped
  `*.min.js` / `.map` artifacts (and their vendored twins under
  `spec/dummy/public/vendor`) are rebuilt — the 1.4 minifier picks different
  local identifier names and sorts export lists, so the bytes differ, but the
  code is semantically identical (JS unit, request, and browser suites unchanged).

- **BREAKING: small sharp knives — the last 0.11 API-clarity pass (#186).**
  Four independent edges honed, one contract frozen:
  - **`reactive_filter` speaks fields, not selectors.** `reactive_filter(:q)` names the
    driving FIELD and compiles it to `[name="q"]` (scope-aware, like `reactive_field`
    from #184); `option:` defaults to `[role=option]`. The old
    `reactive_filter(input: "#search", …)` selector form raises a guided error. The
    client wire is byte-identical (it still receives selectors) — this is a server-only
    compile, no client change. `group:`/`empty:` stay opt-in (emit only when passed).
  - **`transition:` takes named legs.** `js.toggle("#x", transition: { during:, from:, to: })`
    replaces the positional `transition: [during, from, to]` array (which raises with the
    caller's values slotted into the named form). Compiles to the same wire array — zero
    client change.
  - **BREAKING: one registry reader — the plural frozen hash IS the fetch-one.** The seven
    singular getters (`reactive_action`, `reactive_action?`, `reactive_collection_def`,
    `reactive_collection?`, `reactive_compute_def`, `reactive_compute?`, and the bare
    `reactive_compute(:name)` GETTER form) are removed — each raises a guided error naming
    the hash form (`reactive_actions[:name]`, `reactive_actions.key?(:name)`,
    `reactive_computes[:name]`, `reactive_collections[:name]`). The resolved registries now
    come back FROZEN — they are the memoized dispatch table, so mutation raises `FrozenError`
    and can never corrupt default-deny. The `reactive_compute :name, inputs:, outputs:`
    SETTER is unchanged.
  - **`reply.append`/`reply.prepend` accept row kwargs (non-breaking).** Extra kwargs
    (`reply.append(item, to: :items, autofocus: true)`) now thread through to the row
    component's initializer (`ItemRow.new(item:, autofocus: true)`). Additive — no-kwarg
    calls are unchanged.
  - **`defer.phlex_reactive` joins the frozen instrumentation contract (non-breaking).**
    The deferred-render endpoint's `ActiveSupport::Notifications` event now has a
    request-spec contract test driving all five outcomes (`ok`/`no_content`/`invalid_token`/
    `not_found`/`unauthorized`), freezing its `{ component:, outcome: }` payload shape (a
    rename fails CI, like `action`/`render`/`broadcast`). Documented in the README
    instrumentation table and the observability section of the performance docs page.

- **BREAKING: one `broadcast_to` — verbs as kwargs, components as payloads (#185).**
  The 11 `broadcast_*_to` / `broadcast_*_to_each` methods collapse into ONE
  `broadcast_to` where the verb is a kwarg and its value is the payload:

  ```ruby
  # before                                          # after
  Item.broadcast_replace_to(@list, :todos,          Item.broadcast_to(@list, :todos,
    model: @todo, morph: true)                        replace: @todo, morph: true)
  Row.broadcast_append_to(@list, target: t,         Row.broadcast_to(@list, append: item, target: t)
    model: item)
  Counter.broadcast_replace_to_each(keys,           Counter.broadcast_to(each: keys, replace: counter)
    model: counter)
  Badge.broadcast_js_to(user, :alerts, ops)         Badge.broadcast_to(user, :alerts, js: ops)
  ```

  A Hash payload is the component's init kwargs verbatim (`update: { room:, author: }`),
  killing the old `**options` collision (a component with an init kwarg named
  `target`/`morph`/`exclude` is broadcastable again). Payloads can be BUILT
  components, and the new module-level `Phlex::Reactive.broadcast_to(@list, :todos,
  update: TodoCount.new(...), target: "todos-count")` broadcasts a NON-Streamable
  component (a count badge) — instrumented — without hand-rolling the raw channel +
  render. Self-targeting verbs (`replace:`/`remove:`) require a Streamable payload
  (its `#id` is the target); container verbs (`update:`/`append:`/`prepend:`) take any
  component. Every removed method raises a guided error printing the `broadcast_to`
  rewrite. `exclude:`/`visible_to:` still thread to pgbus through the capability-gated
  thread-local path — unchanged (verified against pgbus 0.11.0).

- **BREAKING: `to_stream_morph` is removed — morph is a kwarg (#185).**
  Use `to_stream_replace(morph: true)` (byte-identical wire). `reply.morph` /
  `reply.replace(morph: true)` are unchanged.

- **BREAKING: forms & fields — scope everywhere, one dirty declaration, named schemas (#184).**
  - **`reactive_scope` extends to `reactive_field` and the param unwrap:** a scoped
    field emits `name="scope[field]"` and the endpoint peels one scope level, so the
    schema stays flat. A schema nested under the scope key raises a guided
    `ArgumentError` from BOTH the `action` macro and `reactive_scope` (either
    declaration order).
  - **One dirty declaration — `reactive_dirty`:** `reactive_dirty warn_unsaved: true`
    (class-level) and `reactive_dirty only: %i[title]` replace
    `reactive_root(track_dirty:, warn_unsaved:)` + `reactive_field(dirty:)`. The
    removed kwargs raise guided errors; the emitted DOM is unchanged (zero client
    change).
  - **Named param schemas — `Phlex::Reactive.param_schema`:** register a reusable
    schema in an initializer (`param_schema :todo, title: :string, …`) and resolve it
    with `action :save, params: :todo`, or compose with `{ **param_schema(:todo), … }`.
    Frozen after boot (the `param_type` precedent); an unknown name lists the
    registered ones. `params:` still takes a Hash.
  - **One binding helper:** `reactive_input` / `reactive_select` are removed — use
    `input(**reactive_field(…))` / `select(**reactive_field(…)) { … }` /
    `textarea(**reactive_field(…))`. The stubs raise the rewrite.

- **BREAKING: `reactive_compute` is scope-aware, root-bound, and permit-shaped (#183).**
  - **Bind + listen at the root:** `reactive_root(compute: :name)` emits the compute
    descriptors AND the `input->reactive#recompute` delegation, so fields carry
    ZERO per-field wiring. Conditional binding collapses to one expression
    (`reactive_root(compute: (:split unless @order.persisted?))`; `nil` = no binding).
    `reactive_compute_attrs(...)` raises a guided error naming the new form.
  - **Scope-resolved names:** under `reactive_scope :order`, a bare compute input/
    output `cash` resolves as `[name="order[cash]"]` client-side (the same
    convention `reactive_show`/`reactive_field` use); a bracketed literal passes
    through unscoped.
  - **Permit-style inputs:** `inputs: [:qty, title: :string]` — bare symbols default
    to `:number`, a trailing Hash types the exceptions. The old array form
    (`%i[a b]`) and hash form (`{ a: :number }`) are degenerate cases (zero shim,
    byte-identical wire).
  - **Sinks declare themselves:** every reducer result key paints into any matching
    sink — an owned field iff in `outputs:` (the allowlist), any owned
    `reactive_text` node by presence, any declared `mirror:` id. An `outputs:` entry
    that existed only to reach a text node is now redundant (old declarations keep
    working). `reactive_text(:name)` with no explicit initial seeds its first paint
    from `reactive_values` when covered.

- **BREAKING: `reply` is the only door — the `Response` class verbs are removed (#182).**
  `Phlex::Reactive::Response.replace(self)` / `.morph` / `.update` / `.remove` /
  `.redirect` / `.with` / `.streams` (and the collection class methods) are removed
  as public entry points — each raises a guided `ArgumentError` naming the
  `reply.<verb>` rewrite. Actions return `reply.<verb>` (the subject-bound door added
  earlier); the immutable `Response` value object and its instance chain
  (`.flash`/`.stream`/`.also`/`.js`/`.defer`) are unchanged, so the endpoint reads it
  exactly as before. One concept, one entry point.

- **BREAKING: reactive-collection replies read as Ruby — `to:`/`from:` keywords (#182).**
  The collection name moved from a leading Symbol to a keyword, and the `UNSET`
  sentinel that overloaded `reply.remove` is gone (dispatch keys on `from:`'s
  presence):

  | Before (removed) | After |
  |---|---|
  | `reply.append(:items, item)` | `reply.append(item, to: :items)` |
  | `reply.prepend(:items, item)` | `reply.prepend(item, to: :items)` |
  | `reply.remove(:items, id)` | `reply.remove(id, from: :items)` |
  | `reply.remove` (bare) | `reply.remove` — unchanged (removes self) |

  A Symbol in the model position (the old shape) raises a guided rewrite.

- **BREAKING: one flash contract — `flash_component` is a callable (#182).**
  `Phlex::Reactive.flash_component` is now a lambda the app owns, so the gem no
  longer guesses your component's kwargs (the old hardcoded `new(level:, content:)`
  collided with real flash components):

  ```ruby
  # before: Phlex::Reactive.flash_component = MyFlash   (gem calls MyFlash.new(level:, content:))
  # after:
  Phlex::Reactive.flash_component = ->(level, content) { MyFlash.new(level:, message: content) }
  ```

  Assigning a Class raises a guided error printing the one-line lambda. The internal
  flash builders (`flash_stream`/`flash_html`/`default_flash_html`) are now private.

- **BREAKING: `also_update` / `also_replace` collapse into one `.also` (#182).**
  The lying `html:` kwarg (it accepted components too) and the per-companion method
  choice are gone:

  ```ruby
  # before
  reply.replace.also_update("page_heading", html: @account.name)
  reply.replace.also_replace(SummaryCard.new(account: @account), morph: true)
  # after
  reply.replace.also(page_heading: @account.name)                        # target => content
  reply.replace.also(SummaryCard.new(account: @account), morph: true)    # a component at its own id
  ```

  String content is HTML-escaped, component content rendered — the escaping contract
  is verbatim. `also_update`/`also_replace` raise guided rewrites.

- **BREAKING: the `flash_builder` / `reset_flash_builder!` aliases are removed (#182).**
  They were "permanent aliases" for `stream_builder` / `reset_stream_builder!` that
  contradicted the clean-break rule. Each old name now raises a guided `NoMethodError`
  naming the real method.

### Fixed

- **A pending-state text swap no longer destroys a composite trigger's icon (#181).**
  The former `disable_with:`/`loading:` text swap wrote `trigger.textContent`, which
  **flattens every child node** — a `<button><svg/> Save</button>` lost its icon the
  instant the request enqueued, and it never came back on restore. `busy:`'s swap now
  reads and restores `innerHTML`, so an icon-plus-label trigger round-trips intact.
  Covered by a new composite-trigger browser assertion and a JS child-preservation
  unit test.

- **`exclude:`/`visible_to:` now actually reach pgbus — actor-echo suppression works over SSE (#187).**
  `broadcast_*_to`/`broadcast_*_to_each` passed `exclude:`/`visible_to:` as keyword
  arguments to `Turbo::StreamsChannel.broadcast_*_to`, but turbo-rails swallows
  unknown kwargs into its render locals — so on the pgbus transport the options were
  **silently dropped** and `exclude: reactive_connection_id` never suppressed the
  actor's own broadcast echo. They are now threaded through the thread-locals pgbus
  reads (`Thread.current[:pgbus_broadcast_exclude]`/`_visible_to`), capability-gated
  on `pgbus_streams?` so the Action Cable path is unchanged. Found by the new
  end-to-end pgbus transport suite (below) — the prior unit doubles only proved the
  option was *forwarded to the method*, never that it *reached pgbus*.

### Added

- **Conditional confirm — warn only when the values look suspect (#179).**
  `confirm:` now takes a Hash for soft-validation-before-submit, so the dialog fires
  ONLY when the field values are wrong — instead of a hand-written submit handler that
  inspects fields and calls `confirm()` itself. Two forms, both evaluated client-side
  over the same collected fields `reactive_compute` reads:
  - **Declarative** — `confirm: { when: { total: 0 }, message: "Total is 0 — continue?" }`.
    `when:` reuses `reactive_show`'s conditions language verbatim: a scalar is equals,
    a `Range` is a threshold (`qty: 100..`), an `Array` is membership. Zero JS. The
    dialog fires when the condition MATCHES; a clean value submits silently.
  - **Named predicate** — `confirm: { predicate: "end_before_start", message: "…" }` for
    multi-field logic the single-field form can't express. Register a pure function at
    boot (`setConfirmPredicate("end_before_start", ({ starts_at, ends_at }) => ends_at < starts_at)`),
    the twin of `setComputeReducer`. An unregistered name warns and proceeds without a
    dialog. Works on `on(...)` AND `on_client(...)`. The predicate is soft-validation UX,
    **not authorization** — a user can bypass it and the action still hits the endpoint's
    real authorize/default-deny; never let it stand in for a server-side check.

- **`confirm:` on `on_client(...)` — themed confirmation for zero-round-trip client ops (#178).**
  The client-op path gains the SAME overridable `confirmResolver` gate `on(:action, confirm:)`
  has (#52/#55). A destructive-feeling client op (clear a draft, reset a form) gets the
  app's themed dialog with one line and no round trip:
  `button(**on_client(:click, js.text("#draft", ""), confirm: "Discard this draft?"))`.
  The gate lives in the user-gesture path (`runOps`), never in the shared op applier — a
  server-pushed `reactive:js` op stream must not prompt. `setConfirmResolver` now themes
  both paths at once.

- **CI transport verification matrix — the browser suite runs on Action Cable AND pgbus (#187).**
  The system job is now `server × transport` (Puma/Falcon × cable/pgbus). The pgbus
  cells add a plain `postgres:18` (pgbus vendors the PGMQ schema via its own
  migrations — no extension image) and set `TRANSPORT=pgbus`, so the existing browser
  suite proves the reactive round trip is transport-agnostic, and new `:pgbus`-tagged
  specs prove real cross-tab broadcast delivery + actor-echo exclusion over live
  Postgres SSE. `rake spec:system_matrix` runs the 2×2 locally (pgbus cells skip with
  a note when Postgres isn't reachable); `rake pgbus:prepare_test_db` sets up the DB.
  pgbus remains an optional, non-gemspec dependency — it is now a first-class *tested*
  transport, not a required one.

### Changed

- **BREAKING: ONE pending-state vocabulary — `busy:` replaces `loading:` / `disable_with:` (#181).**
  A trigger's declarative pending affordance is now a single `on(…, busy:)` kwarg
  that shares `optimistic:`'s key vocabulary and normalizer — the only difference
  is the lifecycle (`busy:` reverts on **settle**, `optimistic:` on **failure**).
  `busy:` takes a **String shorthand** (`busy: "Saving…"` ≡ `{ disable: true, text:
  "Saving…" }`) or a **Hash** with the same keys as `optimistic:`
  (`add_class:`/`remove_class:`/`toggle_class:`/`hide:`/`show:`/`disable:`/`text:`/`to:`).
  The removed `loading:` (with its odd `class:` key), `disable_with:`, and the
  `on(…, listnav:)` kwarg each raise a **guided `ArgumentError`** printing the exact
  rewrite. Combobox keyboard nav is now the standalone `reactive_listnav` (composed
  via `mix`), which defaults its option selector to `[role=option]`. Migration:

  | Before (removed) | After |
  |---|---|
  | `on(:save, disable_with: "Saving…")` | `on(:save, busy: "Saving…")` |
  | `on(:save, loading: { disable: true, class: "opacity-50", text: "Saving…" })` | `on(:save, busy: { disable: true, add_class: "opacity-50", text: "Saving…" })` |
  | `on(:search, event: "input", listnav: "[role=option]")` | `mix(on(:search, event: "input"), reactive_listnav)` |

  The wire attribute is renamed `data-reactive-loading-param` → `data-reactive-busy-param`;
  the client keeps a **read shim** for the old attribute for one minor so an
  in-flight page rendered by the previous gem across a deploy keeps its affordance.

- **BREAKING: `reactive_show` speaks ONE conditions language — `if:`/`if_any:`/`unless:` (#180).**
  The four accreted dialects (the positional-field predicate kwargs
  `equals:`/`not:`/`in:`/`gte:`/`gt:`/`lte:`/`lt:`, the `all:`/`any:` term
  arrays, and the `{ equals: … }` target predicate hashes) are **removed** and
  replaced by a single Ruby-native language: a **Hash is an AND**, an **Array is
  membership**, a **Range is a threshold**, `if_any:` is OR-of-AND (one level of
  disjunction — the distributive-law killer), and `unless:` negates. Each removed
  form raises a **guided `ArgumentError`** printing the exact rewrite. Migration:

  | Before (removed) | After |
  |---|---|
  | `reactive_show(:mode, not: "off")` | `reactive_show(unless: { mode: "off" })` |
  | `reactive_show(:gift, equals: true)` | `reactive_show(if: { gift: true })` |
  | `reactive_show(:size, in: %w[l xl])` | `reactive_show(if: { size: %w[l xl] })` |
  | `reactive_show(:qty, gte: 10)` | `reactive_show(if: { qty: 10.. })` |
  | `reactive_show(:amt, gt: 5000)` | `reactive_show(unless: { amt: ..5000 })` |
  | `reactive_show(all: [{ field: :a, equals: "x" }, …])` | `reactive_show(if: { a: "x", … })` |
  | `reactive_show(any: [{ field: :a, equals: "x" }, …])` | `reactive_show(if_any: [{ a: "x" }, …])` |
  | `reactive_show_targets(:m, "#id" => { equals: "x" })` | `reactive_show_targets(:m, "#id" => "x")` |

  New alongside it: **`reactive_values`** computes each binding's first-paint
  `hidden:` server-side (no per-section mirror method, no flash);
  **`reactive_scope :form`** lets bindings use bare field symbols
  (`[name="form[field]"]` on the client); **`disable: true`** disables a hidden
  section's own controls so a switched-away value never submits. The wire is now
  ONE DNF shape (`data-reactive-show='{"any":[[term,…],…]}'`); the client keeps
  legacy read arms for one minor (deploy overlap), removed in 0.11.

- **`Phlex::Reactive::ClientBindings` — a blessed client-only include (#180).** A
  view that only shows/hides, filters, or computes client-side (no server
  actions, no token) includes this instead of the full `Component`. It does NOT
  pull in `Streamable` (so it never clobbers an app's own `replace`/`to_stream_*`
  concern) or the token machinery — a token-less `reactive_root` with no `#id`
  requirement, invisible to `phlex_reactive:doctor`. The full `Component`
  includes it (one implementation), then layers Streamable + Identity on top.

- **Automatic token refresh — `reply.with` and `reply.streams` converge (#180).**
  The action endpoint now appends a `reactive:token` refresh stream automatically
  whenever a reply does not re-render the component's root, instead of prepending
  a full self-replace that could clobber a live input. Picking `.streams` vs
  `.with` to keep the signed token fresh is no longer a correctness decision — a
  companion-only reply refreshes the token either way.

- **BREAKING: `verify_authorized` is ON by default (#168).** A reactive action
  that completes **without any authorization call now raises**
  `Phlex::Reactive::AuthorizationNotVerified` — **rolling back the transaction**
  (fail-closed, stronger than Pundit's after-the-fact check). This is the
  presence-side complement to `authorization_errors`: a forgotten `authorize!`
  becomes a loud 500 your error tracker sees, not a silent hole. The guard
  detects a call to any `Phlex::Reactive.authorization_methods` name
  (default `%i[authorize! authorize allowed_to?]` — Pundit/CanCanCan/ActionPolicy)
  **or** `mark_authorized!`, made anywhere during the action (a helper the action
  calls counts too). **Three remedies** for each action:
  1. call your authorization method (`authorize! @record, :update?`);
  2. call `mark_authorized!` after a bespoke check the interceptor can't see;
  3. declare `skip_verify_authorized` (whole component) or
     `skip_verify_authorized :action_name` (specific actions) for an
     intentionally public action.
  Turn it off globally with `Phlex::Reactive.verify_authorized = false` (the
  install-generator initializer documents the knob). The `action.phlex_reactive`
  instrumentation event gains a new `:unverified` outcome. A new **advisory**
  doctor check flags mutating actions with no detected authorization call
  (heuristic — a helper may authorize indirectly; never a hard fail).

### Added

- **Compound & numeric `reactive_show` predicates — `all:`/`any:` and
  `gte:`/`gt:`/`lte:`/`lt:` (#176).** Value-conditional visibility now spans
  **more than one field** and **numeric thresholds**, staying inside the
  eval-free "declared literal predicate" contract. `all:` / `any:` fold a list of
  per-field terms (`{ field:, equals:/not:/in:/gte:/… }`) with one fixed
  connective — AND vs OR over the same literal vocabulary, no expression surface;
  one flat binding replaces wrapper-div nesting and is the only way to express OR.
  `gte:`/`gt:`/`lte:`/`lt:` compare `Number(value)` against a literal number baked
  into the binding (the RHS must be a real `Numeric` — a typo fails at render); a
  non-numeric field value is `NaN` → hidden, the safe reveal-on-threshold default.
  Numeric predicates work standalone, as a compound term, and inside a
  `reactive_show_targets` map. Malformed terms fold **false** (fail-closed:
  default-deny). The single-field `reactive_show(:field, equals:)` form is
  unchanged; the additions are backwards compatible.

- **Installable Claude debugging skill + `rails g phlex:reactive:claude` (#168).**
  The gem ships a `phlex-reactive-debugging` skill (the doctor → inventory → find
  → browser `report()` → MCP workflow + a failure table) under `lib/`, and the
  new generator copies it into a host app's `.claude/skills/` and writes the MCP
  server entry to `.mcp.json` — only when absent (it never rewrites an existing
  `.mcp.json`; it prints the snippet instead). A new **Debugging & tooling** docs
  page ties the four surfaces together; the security page documents
  `verify_authorized`; the instrumentation table gains the `:unverified` outcome;
  the README gains a Debugging & tooling section + the config rows.

- **On-demand client inspector — `phlex/reactive/inspect` (#168).** A standalone
  JS module (the `confirm.js`/`compute.js` precedent — **zero hot-path cost**, no
  edit to `reactive_controller.js`, loaded only when imported) that scans the live
  DOM and maps every reactive root + bound trigger back to the server
  `Component#action` names. From the browser console:
  `(await import("phlex/reactive/inspect")).report()` prints a `console.table` of
  every reactive root — its `id`, decoded token payload (component class, gid,
  state keys, token version — try/catch base64+JSON decode, degrading to
  `{ opaque: true }` on a Marshal-serialized payload), status attrs, triggers
  (action + event + params + debounce/throttle/confirm), client-only ops,
  computes, the `name`d fields the dispatch would collect, and the
  show/filter/text binding families. Triggers are scoped to the **nearest** root,
  so nested roots aren't double-attributed. The server↔client mapping is
  by-name: `scan()`'s `component` + trigger `action` strings are exactly the
  identifiers `phlex_reactive:actions` and the MCP tools list. Pinned by the
  engine (not preloaded); pure read, never mutates the page.

- **Read-only diagnostic MCP server (#168).** `bin/rails phlex_reactive:mcp`
  starts a stdio [MCP](https://modelcontextprotocol.io) server exposing five
  read-only tools — `phlex_reactive_doctor`, `phlex_reactive_components`,
  `phlex_reactive_actions` (optional `component:` filter), `phlex_reactive_find`
  (fuzzy search + Prism method source), `phlex_reactive_config` (redacted) — so
  Claude Code inside a host app can introspect the live reactive registry when
  debugging. The `mcp` gem is **optional and lazy**: it is NOT a gemspec runtime
  dependency; `Phlex::Reactive::MCP.load!` requires it on demand with a helpful
  message when missing (the pgbus pattern), and the gem-dependent tool tree stays
  out of the Zeitwerk autoloader — a host app without `mcp` boots and eager-loads
  unaffected. Every tool is read-only and non-destructive (no arbitrary-query or
  mutation tool) and reports names/paths/schemas only — never a token, secret, or
  runtime state; `phlex_reactive_config` never emits the verifier or
  `secret_key_base`. Consumer `.mcp.json`:
  `{ "mcpServers": { "phlex-reactive": { "command": "bin/rails", "args": ["phlex_reactive:mcp"] } } }`.
  Known constraint: stdio MCP needs a clean stdout — an initializer that `puts`
  breaks the transport (same caveat as pgbus).

- **verify_authorized runtime guard (#168).** New
  `Phlex::Reactive::Authorization` (fiber-local tracking window, method
  interception, the enforcement decision), `mark_authorized!` instance helper,
  the `skip_verify_authorized` DSL (registry #6, inherits like the other five),
  and `Phlex::Reactive.verify_authorized` / `authorization_methods` config
  (`defined?`-guarded so an explicit override sticks). See the breaking note
  above for the behavior and remedies.

- **Action inventory — `Phlex::Reactive::Inspector` + rake tasks (#168).** A new
  read-only introspection layer that answers "what reactive actions exist in this
  app, where are they defined, and is each authorized?" without grepping.
  `Phlex::Reactive::Inspector.components` discovers every constant-backed reactive
  component from the loaded `Streamable` registry; `.find(query)` fuzzy-matches
  one (exact > prefix > substring > subsequence, on both the demodulized and the
  full name). Each action reports its declared param schema, `file:line`, the full
  `def … end` source (extracted with **Prism**, degrading to `nil` on an
  unreadable/unparseable file — never raising), and a **heuristic** authorization
  status (a Prism scan for a configured authorization method or
  `mark_authorized!` in the body — advisory only, since a helper may authorize
  indirectly). Two shipped rake tasks surface it: `bin/rails
  phlex_reactive:actions` (plain-text table, `FORMAT=json` for tooling) and
  `bin/rails "phlex_reactive:find[query]"` (ranked matches; top match in detail
  with each action's method source). Output is names/paths/schemas only — never
  tokens, secrets, or runtime state (the instrumentation privacy contract
  extended to tooling). `Doctor` now delegates its `constant_backed_component?`
  filter to the Inspector so the endpoint-rebuild predicate lives in one place.

- **Deferred reply segments — `reply.defer` (#165).** An expensive part of a
  reply (a cross-aggregate rollup, a report) no longer stalls the actor's
  interaction: `reply.streams(cheap).defer(SessionTotals.new(workout:))`
  returns the cheap streams immediately and streams the real render to the
  SAME actor when it finishes. Keep-content default (the stale value stays
  visible, marked `data-reactive-defer-pending` + `aria-busy` for CSS
  shimmer); `placeholder: true` / a component swaps a skeleton in;
  `morph: true` morphs the arrival (the mode rides INSIDE the signed token).
  Transactional (the directive rides the post-commit reply — a rollback or a
  denied action leaks nothing), actor-scoped (peers keep `broadcast_*_to`),
  superseding (a newer action for the same target aborts the in-flight
  deferred render — no stale paint), and interactive on arrival (fresh action
  token). Delivery is transport-adaptive (`Phlex::Reactive.defer_transport`,
  default `:auto`): a parallel fetch to the new `POST /reactive/defer`
  endpoint everywhere (purpose-scoped, short-TTL defer token —
  `defer_token_ttl`, default 120s; `reply.defer` tokens are **actor-bound**
  to the requesting session so a leaked one can't be redeemed elsewhere,
  `reactive_lazy` shell tokens are unbound by necessity — they render
  before a session exists — with the TTL + `authorize!` as their bound;
  never interchangeable with action tokens),
  or a **durable pgbus one-shot stream + `DeferredRenderJob`** when pgbus's
  reactive Streams and ActiveJob are present (`defer_job_queue` config; the
  durable since-id replay closes the broadcast-before-subscribe race, and the
  broadcast tears down its own subscription). The push lane's one-shot queue is
  reclaimed by pgbus's age-based orphan-stream sweep (**pgbus ≥ 0.9.10**; run
  the Dispatcher with `streams_orphan_threshold` set); we never eager-drop it
  (that would reopen the delivery race). The one-shot key is sized to the live
  pgbus `queue_prefix` budget, so a non-default prefix can't overflow it; the
  render job broadcasts a cleanup on ANY failure so the actor's pending state
  always resolves. Every capability gap degrades to the fetch lane — the
  Action-Cable-or-pgbus invariant holds. **Profile first:** an app-side N+1
  looks exactly like framework lag; defer is for segments that are genuinely
  expensive after the synchronous path is cheap.

- **Lazy initial mount — `reactive_lazy` (#165).** The same machinery for the
  FIRST render (Livewire `#[Lazy]`): the page ships the component's
  placeholder shell (`deferred_placeholder`, or a built-in pending shell) with
  the defer token on the root; the client fetches the real content on connect
  AND after a Turbo page-refresh morph (so a lazy component survives a
  `turbo:reload`). `reactive_lazy tag: :tr` (etc.) ships a shell element that
  matches a `<tr>`/`<li>` root instead of an invalid `<div>`.
  Reactive-machinery renders (an action's self-replace, broadcasts, the defer
  endpoint/job) stay REAL, so actions never pay two round trips.

- **pgbus capability gates.** `Phlex::Reactive.pgbus?` and `.pgbus_streams?`
  (the documented broadcast-accepts-`:exclude` probe, now actually
  implemented) plus `.defer_push_capable?` for the defer push lane.

- **Client-side option filtering — `reactive_filter` (#163).** The other half
  of #72's combobox: **preload the options, type to narrow — zero round
  trips.** Spread `reactive_filter(input:, option:, group:, empty:)` onto the
  root and the generic controller shows/hides each option on every keystroke by
  a case-folded substring match against its `data-reactive-filter-text`
  haystack (falling back to the option's own text) — no POST, no token, no
  bespoke per-feature Stimulus controller. Optional `group:` collapses a header
  whose every contained option is hidden; optional `empty:` reveals a
  no-matches node at 0 visible. Selectors resolve within the root only (nested
  reactive roots untouched), state seeds at connect and re-applies after a
  morph, and blank selectors raise at render (a dead binding must fail loudly).
  Composes with keyboard nav and per-row selection: a filtered-out option also
  drops out of the Arrow-key path and loses its highlight, so Enter can never
  pick an invisible row — selection itself stays a signed `on(:select)` action.
- **Standalone combobox keyboard nav — `reactive_listnav` (#163).** The same
  Arrow/Enter/Escape wiring `on(…, listnav:)` appends, without the dispatch
  descriptor — for the preload-and-filter input that fires **no** action (an
  `on()` trigger would POST per keystroke). Spread
  `reactive_listnav("[role=option]")` onto the input; Enter still picks by
  clicking the highlighted option's own signed trigger.
- **Cross-root `reactive_show` targets — `reactive_show_targets` (#164).** A
  field can now drive the visibility of declared elements **outside** its
  reactive root — the nav tab, the panel in another tab pane, the sidebar note
  a mode selector governs — the visibility parallel to the #159 cross-root
  text mirror. The component that **owns** the field declares which outside
  ids it governs, spread on the root:
  `mix(reactive_root, reactive_show_targets(:mode, "#advanced-tab" =>
  { equals: "advanced" }, "#basic-note" => { not: "advanced" }))`. Same
  posture as `mirror:`: opt-in and declared, never implicit (a plain
  `reactive_show` stays root-isolated, #15 untouched); targets are **single id
  selectors only** — a class/compound selector raises at declare time AND is
  warn-and-skipped by the client (two-sided default-deny); the predicate is
  the same literal-only `reactive_show` vocabulary; the toggle is `hidden`
  only. The field read stays **owned** — you can only drive outside visibility
  from a field the declaring root owns. A target id not on the page is
  silently skipped (an unrendered tab pane is normal); the cross-root pass
  shares the owned-binding pass's field-read memo (one read per field per
  sync). No map declared → one `getAttribute` and out. **One call per root**:
  Phlex `mix` space-joins duplicate string data values, so a second call's
  JSON would corrupt the attr (the client warns and ignores it) — several
  fields go in one call via the hash form
  (`reactive_show_targets(mode: { … }, kind: { … })`).
- **Value-conditional visibility — `reactive_show` (#161).** The `x-show` /
  `data-show` / `wire:show` case — show/hide an element from a form field's
  **current value** — no longer needs a hand-written `change`-listener Stimulus
  controller. Spread `reactive_show(:mode, not: "off")` onto the element to
  show/hide (also `equals:` and `in: [...]`; `equals: true` reads a checkbox's
  checked state, a radio group reads the checked radio's value) and the generic
  controller toggles the `hidden` attribute on every `input`/`change` —
  client-only, zero round trip, no token. The predicate is a **declared literal
  match**, never an expression (no eval surface); exactly one predicate is
  enforced loudly at render; a missing field or malformed wire attr is
  warn-and-skipped (client-side default-deny). Visibility seeds at connect and
  re-syncs after a `turbo:morph-element`; a `reactive_compute` output write
  dispatches a real `input` event, so derived values drive visibility too.
  Ownership follows the nested-root rules (#15). Roots without a binding pay
  one connect-time probe — no new listeners, byte-identical wire.

- **Cross-root text mirrors + the `text` client op (#159).** A derived value can
  now be painted into a text node **outside** the computing component's reactive
  root — the read-only recap in another tab pane that previously forced a
  bespoke JS listener — with the library's default-deny posture intact:
  - `reactive_compute ..., mirror: { sum_total: "#sum_total" }` declares
    allowlisted cross-root text mirrors. Each compute pass paints every declared
    name into its document-wide **id** target(s) via `textContent`
    (change-guarded, never `innerHTML`, never blanks a name the pass produced no
    value for). The value comes from the reducer result, a just-written output's
    field, or a declared input's identity value — so it works with no reducer at
    all. Non-id selectors raise at declare time AND are warn-and-skipped by the
    client interpreter (two-sided default-deny). No `mirror:` → the wire is
    byte-identical to before.
  - `js.text(to, value, global: false)` — a new op that sets `textContent`
    (stringified; `nil` clears), available to `on_client`, `reply.js`, and
    `broadcast_js_to`. Strictly less powerful than `set_attr`; pair with
    `global: true` for the cross-root paint.
  - `global: true` is now honored on the `reactive:js` stream path: a single op
    can opt out of the reply's target-root scope to document-wide resolution
    (previously it was silently ignored when a `target` was set).

### Performance

- The defer machinery adds nothing measurable to the existing hot paths
  (same-machine, same-checkout before/after vs `main`): `to_stream_replace`
  14.4k → 14.2k i/s (within ±3.7% noise), identity token 199.9k → 196.7k i/s
  (state-backed) / 93.7k → 93.5k (record-backed), allocations byte-identical.
  New `benchmark/micro/defer_token.rb`: `sign_defer` ~120k i/s, `verify_defer`
  ~99k i/s, full fetch-lane directive build ~11 µs/segment, 0 retained. Defer
  is a **latency-shape** change, not a throughput one — the A/B spec
  (`spec/requests/deferred_latency_spec.rb`) pins that a 120 ms segment cost
  moves OFF the actor's reply and onto the deferred leg; it never disappears.

## [0.9.0] - 2026-07-03

Consolidates everything since 0.2.6; tags 0.2.7–0.4.8 shipped without changelog
sections, so this section spans the whole run to 0.9.0. The jump from 0.4.8 to
0.9.0 signals the Tier-2 API wave (#79–#120) and the run-up to 1.0, leaving 0.9.x
room for dogfood fixes.

### Upgrading from 0.4.x

- **BREAKING — an unknown param-type symbol now raises at boot, not at click
  time (#109).** A `params:` schema declared with a type the library doesn't know
  (a typo like `:strng`, or a type you meant to register) raises
  `Phlex::Reactive::UnknownParamType` when the component class loads — the schema
  is compiled once at declaration. Fix the typo or register the type. Previously a
  bad type symbol slipped through to the request and failed obscurely per click.
- **Minimum Ruby is now 3.4** (was 3.2). Enabling the `it` block parameter
  requires 3.4, so `required_ruby_version` is `>= 3.4.0`. Stay on the 0.3.x line
  if you need Ruby 3.2/3.3.
- **`optimistic:` / `loading:` / `disable_with:` are now RESERVED `on(...)`
  keywords** (#98, #99), joining `window:` / `once:` / `outside:` / `throttle:`
  from #80. If an action of yours took a free param literally named `optimistic`,
  `loading`, or `disable_with`, rename it — those names now configure the
  client-side hint/loading behavior instead of passing through as an action param.
- **`flash_builder` → `stream_builder` rename (#113) — no action needed.** The
  builder does far more than flashes, so it was renamed;
  `Phlex::Reactive.flash_builder` and `reset_flash_builder!` remain **permanent
  aliases** (no deprecation). Listed only for grep-ability if you referenced the
  old names.
- **The client runtime now ships pre-minified (#148) — zero change for importmap
  consumers.** The engine pins the `.min.js` build (106 KB → 22 KB, ~7.7 KB
  gzipped) with a linked sourcemap, so devtools still shows readable source. If
  you vendor the client file by hand, re-vendor from the minified build (the
  dummy app's `spec/dummy/public/vendor/reactive_controller.js` is that build).

### Security

- **The signed-token version (`v`) now fails closed on a malformed value.**
  `upgrade_token` type-guards `v` before comparing it: a non-integer or negative
  `v` (only producible with the signing key, or by operator error — `v` lives
  inside the signed blob) now returns `nil` → `400` through the endpoint's
  `|| raise(InvalidToken)`, instead of a 500 on the `v > TOKEN_VERSION`
  comparison or silently treating a negative `v` as a legacy passthrough. The
  fail-closed-on-rollback contract (a `v` newer than this code understands → 400)
  is unchanged.
- **The raw-array `js([...])` / `broadcast_js_to([...])` escape hatch now
  re-applies the attribute-name allowlist server-side.** The `JS` builder rejects
  event-handler (`on*`), URL-bearing, and `style` attribute names at build time;
  the raw `[[op, args], …]` form skipped that Ruby-side check and relied on the
  client interpreter alone. `Phlex::Reactive::JS.assert_ops_allowed!` restores
  full server-side parity (defense in depth — the client still enforces it too),
  so a hand-built ops array can't emit an `onclick`/`href`/`style` attr op.

### Changed

- **One inheritance-aware registry behind the Component DSL; `component.rb` split
  into cohesive concerns (#115).** All five class-level registries
  (`reactive_actions`, `reactive_state_keys`, `reactive_collections`,
  `reactive_computes`, `reactive_record_key`) now resolve through
  `Phlex::Reactive::Component::Registry` with ONE semantic:
  resolve-through-superclass at read time, memoized per class against a
  generation counter bumped on any registry write. **The one visible behavior
  change** (previously divergent): a parent class declaring an action/state
  key/collection/compute AFTER a subclass had been read is now visible to that
  subclass — pre-#115 the four collection registries snapshot-dup'd the parent
  on first access (the late declaration was silently invisible), while
  `reactive_record_key` walked live; the hot-path identity memos could go stale
  split-brain against the live key. All covered by the new registry-inheritance
  contract suite. Zero public API change: every reader keeps its exact
  signature, `reactive_compute_def(name)` is added as the reader form matching
  `reactive_collection_def` (the `reactive_compute(name)` getter stays a
  permanent alias), and the token hot path is measured byte-identical
  (unchanged i/s within noise; identical allocations). `component.rb` is now an
  aggregator over `component/{registry,dsl,identity,helpers}.rb` — pure code
  motion, constant paths unchanged.

### Performance

- **Ship a minified client runtime — `reactive_controller.js` 106 KB → 22 KB
  (−79%; ~7.7 KB gzipped).** The authored client modules are comment-dense on
  purpose (the source is the documentation, and the JS suite imports it), so the
  gem no longer ships that source to browsers. `rake build:js` (bun) produces a
  minified twin of each module — `reactive_controller.min.js`,
  `confirm.min.js`, `compute.min.js` — each with a linked sourcemap that
  embeds the original source, so devtools still shows the readable code. The
  engine now pins and precompiles the `.min.js` (plus its `.map`); the bare
  specifiers are unchanged, so **no consumer edit is required** — importmap apps
  transparently load the small file. The confirm/compute override seams stay
  separately pinned (not bundled in), so `import { setConfirmResolver } from
  "phlex/reactive/confirm"` still works. The bun minifier output is
  deterministic (byte-identical across bun patch releases), so the artifacts are
  committed and shipped in the gem — consumers need no bun — and CI (`rake
  build:js_check`) rebuilds and fails on drift. The system suite now runs the
  vendored minified build in a real browser under both Puma and Falcon, so the
  code that ships is the code that is proven. Measured on bun 1.3.14.
- **Multi-key broadcast fan-out is ~9.5× faster (#119).** Measured, transport
  doubled out, K=10 stream keys: a hand loop over `broadcast_replace_to` →
  `broadcast_replace_to_each` moves 2.88k i/s (347 μs) → 27.3k i/s (37 μs)
  (**9.5×**, and within ~4% of a single 1-key broadcast — K renders + K HMACs
  collapse to 1 + 1), allocations 1250 obj / 186 KB → 151 obj / 22 KB (**−88%**
  objects, 0 retained). Same-machine before/after on the new
  `benchmark/micro/broadcast.rb`; numbers on the performance docs page.
- **`#extractToken` per-id regex memoization (#118).** The client's
  `#extractToken` (`reactive_controller.js`) compiled its two self-matching
  `RegExp` objects — the `reactive:token` matcher and the self replace/update
  matcher — on **every** response, even though the root's `id` is page-stable.
  They are now memoized on the instance keyed on `this.element.id`, rebuilt only
  when the id changes (a re-render that re-identifies the root must scan for the
  new target, never a stale one — covered by a new id-change bun test). The regex
  **patterns are byte-identical**; only their allocation moved, so token
  self-matching semantics are unchanged (the #44/#46/#47 pins stay green).
  **Measured, not assumed** (`rake bench:client`, bun 1.3 / M2 Max): before/after
  is within run-to-run noise (~4.4 µs on a 2 KB body, ~9–11 µs on a 500 KB 200-row
  collection, both sides), because `#extractToken` is already **~0.25% of the
  `DOMParser` ceiling** (~4 ms on that 500 KB body) — removing two allocations per
  call sits below the timing floor of the dispatch-driven bench. It is a
  correctness/cleanliness win on a hot path, **not** a throughput change; per the
  issue's decision rule, recorded as "measured — not worth further optimization"
  and closed.

### Added

- **`broadcast_*_to_each` — render-once, multi-key broadcast fan-out (#119).**
  `broadcast_*_to` concatenates its `*streamables` into ONE stream key, so
  pushing the same component to K DIFFERENT keys (a per-tenant loop — "the list
  page stream AND the dashboard stream") with a hand-written loop was K builds +
  K renders + K identity HMACs for BYTE-IDENTICAL HTML. Every verb now has an
  `_each` sibling — `broadcast_replace_to_each` / `_update_` / `_append_` /
  `_prepend_` / `_remove_` — taking an enumerable of stream keys (each a
  `[record, :symbol]` pair or a bare string): it renders the component **once**
  and loops only the cheap channel call. Transport opts (`exclude:` /
  `visible_to:`) and `morph:` forward **per key** exactly as the single-key verbs
  do, so the pgbus path suppresses the actor's echo on every stream and the
  Action Cable path is unchanged (the no-opts call passes no unknown keyword —
  the pgbus-optionality invariant holds; the old-pgbus-shape double guards the
  `ArgumentError` regression). Per-VIEWER `visible_to:` content (different HTML
  per viewer) stays the irreducible render-per-call case. Pure composition of the
  existing private helpers; no change to any single-key method.
- **`benchmark/micro/broadcast.rb` — the missing broadcast bench (#119).** The
  broadcast render path was a named hot path (`.claude/rules/performance.md`)
  with no bench. It doubles the transport out and measures the server-side
  build + render + HMAC cost at 1 key, a hand K-key loop, and `_to_each` over K
  keys — auto-discovered by `rake bench:micro`. It also benched `model_param_name`
  (the audit's measure-first candidate: 815k i/s, 8 obj/call — immaterial next to
  the ~37 μs build, so **measured and left alone**, no memoization).
- **`benchmark/micro/verify.rb` — isolate token verify/sign cost; the
  digest/serializer question is now measured and closed (#120).** `verify` runs
  before anything else on every reactive request (a garbage-token flood pays it),
  and `sign` runs once per rendered component (N× for an N-row collection) — yet
  neither had ever been measured in isolation (`token.rb` covers sign-side
  *assembly*, not the HMAC), and the default digest/serializer was never compared.
  The new bench (auto-discovered by `rake bench:micro`, no harness change) reports
  four verify cost classes — **valid** state/record (~136k/147k i/s, 20 obj), a
  **tampered** token that pays the full constant-time HMAC compare (~203k i/s,
  ~6× slower than garbage), and a **garbage** flood that bails at format parsing
  (~1.2M i/s, 4 obj) — plus `sign` ×1 (~155k i/s, 12 obj) and the **collection
  cost** `sign` ×100 (~1.6k i/s, 1200 obj, linear). It also compares the app
  default (SHA1, json+marshal) against SHA256 and a strict JSON serializer for
  both verify and sign: **every variant falls within measurement noise**, so
  phlex-reactive **ships no runtime change and no opt-in recipe** — the setter
  (`Phlex::Reactive.verifier = …`) is documented as the escape hatch if your own
  profile ever shows verify hot, but the data says it will not. Verification
  semantics, purpose scoping, and default-deny are untouched — this issue
  *measures*. Numbers and the "measured, closed" verdict are on the performance
  page. Pure tooling + docs; no production-code change.

- **Client dispatch micro-bench harness — `rake bench:client` (#116).** The client
  hot path (`app/javascript/.../reactive_controller.js`) was named a hot path in
  `.claude/rules/performance.md` but had **no bench of any kind** — every claim
  about `#extractToken` / `#collectFields` / `recompute` cost was a guess the
  perf prime directive forbids, and it blocked the client-perf issues that need a
  before/after. `benchmark/client/` now holds bun-runnable
  [mitata](https://github.com/evanwashere/mitata) benches that drive those three
  paths through the controller's **public surface only** (`dispatch()` /
  `recompute()`) — **no `__bench` exports, nothing under `app/javascript/`
  changes**, so the vendored-client re-sync rule is never tripped. `rake
  bench:client` shells to `bun run benchmark/client/index.bench.js`, writes
  `tmp/benchmarks/client.txt` alongside `micro.txt`, and **fails the task on a
  crashed bench** (mitata runs with `throw: true`, matching the `bench:micro`
  contract). New dev-only dependencies: **mitata + happy-dom** (a JS DOM engine
  for the `collectFields`/`recompute` fixtures). Baselines are documented on the
  performance page with honest framing: the happy-dom numbers are
  **engine-relative** (valid for same-machine before/after deltas, not an
  absolute browser cost), while the regex-only `#extractToken` numbers are
  **engine-faithful** under bun/JSC. Pure tooling — no production-code change.

- **`morph:` on the update verbs (#113).** The `update` family now takes the same
  `morph:` flag `replace` already had, closing the verb-matrix asymmetry: Turbo 8
  supports `method="morph"` on `action="update"`, so an inner-HTML update can morph
  in place instead of swapping. This matters most for a **cross-tab
  `broadcast_update_to`** into a component a peer is editing — a plain update tore
  down their focus/caret; `morph: true` patches the inner HTML in place and keeps
  it. Threaded through every update surface:
  - `Streamable.update(model, morph: true)` (class builder) and
    `#to_stream_update(morph: true)` (instance primitive) — emit
    `method="morph"`.
  - `broadcast_update_to(*streamables, morph: true)` — carries the attr through
    `attributes:` (the broadcast path has no `method:` kwarg), so it works on
    **both** Action Cable and pgbus; the pgbus-absent fallback is unchanged.
  - `Response.update(component, morph: true)` and `Reply#update(morph: true)` —
    `reply.update(morph: true)`.

  **Default `false` everywhere → byte-identical to today** (no `method=` attribute),
  so existing components are unaffected. No new dependency — Idiomorph ships with
  `turbo-rails >= 2.0`.

- **Component-aware `around_action` seam (#112).** Register a wrapper with
  `Phlex::Reactive.around_action { |ctx, &action| … }` and it folds into the
  endpoint **between** `with_connection_id` and the action's transaction — so it
  sees the resolved component instance, the declared action name, and the
  **coerced** params (a frozen `Phlex::Reactive::ActionContext`), and a rejection
  never opens a transaction. This is the seam for audit logging, component-aware
  rate limiting, and assertions; the base controller (`base_controller_name`)
  stays the seam for HTTP-layer concerns (auth, CSRF, coarse per-IP throttling)
  that don't need the resolved action. Contract: **each wrapper MUST return
  `action.call`'s value** — the endpoint type-checks the action's return for a
  `Phlex::Reactive::Response`, so a wrapper that returns its logger's result
  silently downgrades every reply to the implicit self-replace. A wrapper raising
  a registered `authorization_errors` error renders as 403; an unregistered raise
  is a 500. Wrappers nest in registration order (last-registered outermost). The
  empty stack (the default) adds only one `Array#empty?` check to the hot path;
  `Phlex::Reactive.reset_around_actions!` resets it for tests. See the README
  "Two seams" section and the security page.

- **Versioned identity-token payload + upgrader chain (#111).** Every signed
  token now carries a `"v"` key (`Phlex::Reactive::TOKEN_VERSION`, currently `1`),
  and `Phlex::Reactive.verify` runs the payload through an upgrader chain before
  your component rebuilds from it. This is infrastructure for the NEXT breaking
  shape change (a rename, per-token expiry, a nonce): instead of every open page
  breaking at deploy — an old-shape token verifies fine, then blows up later in
  `from_identity` — the old payload upgrades transparently. Contract:
  - A token minted **before** versioning existed carries no `"v"`; it is read as
    version 0 (today's shape) and passes through byte-identical — introducing
    versioning **invalidated nothing in flight**.
  - When you change the shape, bump `TOKEN_VERSION` and register
    **`Phlex::Reactive.register_token_upgrader(old_version) { |payload| … }`**;
    upgraders run oldest → current.
  - A token from a **newer** version than the running code (a rolled-back deploy)
    **fails closed** — `verify` returns `nil`, so the endpoint answers 400, the
    same path as a tampered token. Never fail-open.

  `from_identity` ignores the extra `"v"` key, so existing components are
  unaffected. Perf: the one added key costs +3 objects / +480 bytes per
  `reactive_token` (a single `Hash#merge`); HMAC signing dominates and is
  unchanged, so throughput is within measurement noise.

- **Public `Phlex::Reactive::TestHelpers` + a no-HTTP `run_reactive` action
  driver (#110).** The gem now ships the test surface it used to keep private.
  Mix it in (`config.include Phlex::Reactive::TestHelpers`) for:
  - **`run_reactive(component, :act, **params)`** — the no-HTTP unit driver. It
    runs the action through the SAME security contract the endpoint enforces —
    **default-deny** (an undeclared action raises
    `Phlex::Reactive::TestHelpers::UndeclaredReactiveAction`), the **signed
    identity round-trip** (a record-backed component's row is re-found; a deleted
    record raises `ActiveRecord::RecordNotFound`, the endpoint's 404), **schema
    coercion** (#109), and the same **transaction wrapper** — with no HTTP, and
    returns a `Result`. A registered authorization error RAISES (the endpoint
    maps it to 403). So a unit test can no longer pass on a component that would
    fail a real click.
  - **`Result`** — wraps the action's return: `replace?` / `remove?` /
    `redirect?` / `redirect_url` / `streams` / `response`, plus `component` (the
    instance rebuilt from identity — the one the action ran against). A legacy
    action returning an arbitrary value reads as an implicit replace.
  - **`reactive_token_for(component_or_class, payload = {})`** — mint a token the
    way a component does (class form via the public `Phlex::Reactive.sign`;
    instance form wraps the private `reactive_token`). No more
    `component.send(:reactive_token)`.
  - **`post_reactive_action` / `post_reactive_multipart`** — POST a signed token
    to **`Phlex::Reactive.action_path`** (never a hardcoded `/reactive/actions`,
    so a remounted path is honored) exactly as the client encodes it.
  - **Matchers** `have_reactive_replace`, `have_reactive_remove`,
    `have_reactive_token_for` (RSpec; loaded only when RSpec is present, so a
    Minitest app asserts on `Result` predicates directly). The token matcher pins
    the #44/#46 refresh regression class for adopters.

  The gem's own request suite now runs THROUGH the public module (dogfooding),
  and the component-generator spec template + the testing docs teach the public
  API — every `send(:reactive_token)` instruction is gone.

- **`Phlex::Reactive::ParamSchema` — declaration-time validation + app-registerable
  param types (#109).** The ~200 lines of param coercion moved out of
  `ActionsController` into a standalone `Phlex::Reactive::ParamSchema`, **compiled
  once** when you declare an action (`ParamSchema.compile(params)`) instead of
  interpreted on every request. Two adopter-facing wins:
  - **Typos fail loud, at boot.** A schema naming an unknown type symbol
    (`params: { count: :interger }`) now raises
    **`Phlex::Reactive::UnknownParamType`** (an `ArgumentError` subclass) at class
    load — validated recursively through nested-hash and array-of-hash element
    types — instead of silently coercing the value to a `String` at click time.
  - **New built-in types + custom registration.** `:date`/`:datetime` (ISO8601,
    dropped on a parse failure) and `:decimal` (`BigDecimal`, dropped on a
    non-numeric value) join the built-ins, so a date/decimal param no longer needs
    `:string` + hand-parsing. Register your own with
    **`Phlex::Reactive.param_type(:money) { |v| … }`** in an initializer — return
    `Phlex::Reactive::ParamSchema::DROP` to reject a value (the keyword default
    then applies, keeping the drop-don't-fabricate contract). The registry is
    frozen after boot, so registration is initializer-only.

  Behavior is otherwise **byte-for-byte identical**: every existing built-in keeps
  its exact semantics (`"abc".to_i → 0`, not a drop; the `:file` duck-type drop;
  the array/hash drop rules; the `#16`/`#21`/`#24`/`#39` bracket-expansion and
  deep-merge matrix), and the `verbose_errors` dropped-param collector (`#82`/`#87`)
  threads through unchanged — a `nil` collector is still the zero-cost production
  path. Coercion is now unit-tested directly (`spec/phlex/reactive/param_schema_spec.rb`)
  in addition to the request-spec integration cover. Bench (`rake bench:one[coerce_params]`),
  same machine: ~35.5k → ~36.0k i/s, 207 → 202 obj/call (the memoized `Boolean`
  type replaces a per-call instantiation), 0 retained — unchanged within noise.

- **Client debug mode (devtools-lite) — `console.group` every dispatch (#108).**
  The `LogSubscriber` (#107) is the *server* lens; this is the *client* one. Set
  `Phlex::Reactive.debug = true` (default off; the initializer template suggests
  `Rails.env.development?`) and `reactive_attrs`/`reactive_root` stamp
  `data-reactive-debug="true"` on the root — the string `"true"`, not a
  boolean-true attr, which Phlex renders valueless and the client would read as
  falsy. The generic controller then `console.group`s **every dispatch** with the
  action, the explicit param **names** + collected sibling-field **names** (never
  their values — they may be sensitive), the request encoding (`json`/`multipart`),
  the HTTP status, the response's stream actions + targets (parsed from the body
  the controller **already read** — no re-fetch), whether a token refresh arrived
  (a boolean — **never the token value**), and the round-trip ms:
  `▼ reactive #todo_42 rename → 200 (48ms)`. This finally surfaces the
  *successful-but-wrong* path (the #30/#44/#46/#50 token-threading series: which
  streams arrived? did a refresh come?), which `console.error` + the #79 lifecycle
  events never covered. **Zero cost when off** — one attribute check per dispatch,
  no string building — measured on the render/token micro benches: **0 extra
  allocations** per render and no throughput change. See the Client debug mode
  section of the README.

- **`ActiveSupport::Notifications` on the hot paths + an opt-in `LogSubscriber`
  (#107).** The gem now emits three events under the `phlex_reactive` namespace,
  so an APM (AppSignal, Datadog, Skylight) sees reactive traffic at the
  **component level** — which component/action a slow request was, render time,
  and broadcast fan-out — where before it saw nothing:
  - `action.phlex_reactive` — one per request; payload `component`, `action`,
    `outcome` (`ok`/`denied_undeclared`/`invalid_token`/`not_found`/`unauthorized`).
  - `render.phlex_reactive` — per render; payload `component`, `bytesize`.
  - `broadcast.phlex_reactive` — per `broadcast_*_to` (fires on Action Cable
    **and** pgbus); payload `component`, `stream_action`, `streamables` count.

  Payloads carry **names, the outcome, and sizes only** — never the token,
  params, or state, so an event can't leak a secret; an `invalid_token` event has
  no trusted component name (the token didn't verify) and omits it. Statuses and
  the endpoint flow are unchanged — the instrument only wraps the existing paths.
  An unsubscribed `instrument` is cheap (a few objects per call, **zero
  retained** — measured on the render micro bench) so the hot paths carry it
  unconditionally. Flip on `Phlex::Reactive.log_events = true` (default off) to
  get one compact debug line per event: `[reactive] Counter#increment ok (3.1ms)`.
  See the Observability section of the README and the performance docs page.

- **`bin/rails phlex_reactive:doctor` — validate the whole install (#106).** Five
  closed issues (#3 boot/eager-load, #26 route shadowing, #42 lost request, #48
  unregistered controller, #57 importmap 404) were pure integration papercuts
  that only surfaced **after** something already broke. The doctor turns "nothing
  happens, why?" into an actionable checklist you run before or after setup. It
  prints `✓/✗/?` with a fix for each failure and checks: the action route
  resolves (reuses the boot route-shadow guard), the `reactive` controller is
  registered in a Stimulus entrypoint (importmap **or** esbuild/bun **or** a
  layout), `csrf_meta_tags` is referenced (**advisory `?`** — never a hard fail,
  so a Phlex-only layout isn't false-flagged), the identity verifier round-trips,
  `base_controller_name` constantizes, every declared `action :name` has a public
  method (mirrors the endpoint's `public_send`), and every component resolves a
  stable `#id` (a state-backed class with no `#id` is flagged; a record-backed
  class on the #81 default is fine). It is **read-only** — no client surface, no
  component instantiation, default-deny untouched — and exits non-zero on a hard
  failure so CI or a setup script can gate on it.
- **Install generator hardening (#106).** The generator now also detects
  `app/javascript/application.js` (esbuild/bun/webpack) as a Stimulus entrypoint,
  not just the importmap-style `controllers/index.js`, and its post-install output
  ends by telling you to run `bin/rails phlex_reactive:doctor` to verify.

### Performance

- **Nested-root fast path for the client field walks (#117).** `#collectFields`,
  `recompute`, and `#listnavOptions` computed field ownership (the issue #15
  "is this element mine, not a nested reactive root's?" check) with a per-element
  `el.closest('[data-controller~="reactive"]')` walk on every matched field —
  `recompute`'s `#ownedField` did a **fresh** `querySelectorAll('[name="…"]')` +
  `closest()` filter **per declared input AND per output on every keystroke**
  (~60 DOM queries on a 30-field calculator). A new `#ownershipFilter()` hoists
  the decision to **once per op**: with no nested reactive root (the common case)
  it returns a constant-true predicate and the per-field `closest()` walk is
  skipped entirely; when a nested root is present it falls back to the exact
  `#ownsField` closest() check, so issue #15 scoping is byte-identical. `recompute`
  additionally resolves its inputs and outputs through a per-call, **first-wins**
  `byName` memo (`if (owns(el)) break` on the first owned match — last-wins would
  change radio-group / Rails hidden+checkbox behavior). Measured same-machine
  before/after (bun + happy-dom, engine-relative): **recompute ~31 µs → ~23 µs per
  keystroke (~25%)** on the 30-input calculator, 0 retained bytes/call;
  `#collectFields` (once per dispatch, dominated by the dispatch overhead) stays
  within noise. A **method/keystroke-level** win, not a request-level one. Field
  ownership is unchanged for every component; the issue #15 nested-root bun tests
  pass untouched. New coverage: `spec/javascript/reactive_recompute_ownership.test.js`
  proves first-wins resolution for duplicate owned names and nested-root rejection.

### Changed

- **Structured `Phlex::Reactive::Stream` value object — the endpoint stops
  regex-sniffing its own generated turbo-stream HTML (#114).** The action endpoint
  used to reverse-engineer stream *semantics* out of *markup*: it substring-scanned
  every stream for `data-reactive-token-value` and regexed the opening
  `<turbo-stream>` tag's `action="…"` against a self-render allowlist to decide
  whether a stream already refreshed the component's signed token. The gem was
  parsing strings it had just built, and every new stream shape needed a new patch
  to the heuristics. Now every `to_stream_*` instance primitive and every
  `Streamable` class builder (`replace`/`update`/`append`/`prepend`/`remove`)
  returns a `Phlex::Reactive::Stream` — an `ActiveSupport::SafeBuffer` subclass
  that IS an html_safe String (so it drops into `render turbo_stream:`, ERB/Phlex
  interpolation, and Turbo test-helper substring asserts unchanged) but also
  carries `rx_action` / `rx_target` / `rx_renders_root?` set **structurally at
  construction** plus `rx_carries_token?` computed **once from ground truth** (a
  build-time scan of the actual bytes, never inferred from the builder kind — the
  cosmos#1939 guard). The endpoint reads those fields instead of regexing markup;
  `renders_root: false` on `append`/`prepend` encodes the #44 lesson (a child row's
  own token in an append `<template>` can never count as the container's refresh)
  in the *type*, not a regex. Raw strings (`reply.with(…)`, interpolated or
  `gsub`'d streams) keep the pre-#114 regex path as a permanent fallback, gated on
  `stream.is_a?(Stream)`. **The wire format is byte-identical** — same
  token-refresh decisions (#30/#44/#46/#50 pins all green), different mechanism.
  This is an architecture/correctness win, not a speedup: `rake bench:request`
  before/after moves within measurement noise (allocations +1 obj/req state-backed,
  +5 obj/req record-backed; throughput swings inside the ±15–28% error bars).

- **`Phlex::Reactive.flash_builder` → `stream_builder` (and `reset_flash_builder!`
  → `reset_stream_builder!`) (#113).** The memoized `Turbo::Streams::TagBuilder`
  is used well beyond flashes — `reactive_collection` row removal, count-companion
  updates, `also_update` — so the `flash_` name misled. Renamed to `stream_builder`
  / `reset_stream_builder!`. **`flash_builder` and `reset_flash_builder!` stay as
  permanent aliases** (no deprecation warnings), so the engine's reload hook and
  any app code keep working unchanged. Purely a rename — behavior is identical.

- **BREAKING (declaration-time): an unknown param type symbol now raises (#109).**
  Before, a schema naming a type the coercer didn't recognize (a typo like
  `params: { count: :interger }`, or a type never registered) fell through to a
  silent `String` coercion. Now `Component.action` compiles the schema through
  `Phlex::Reactive::ParamSchema.compile` and raises
  **`Phlex::Reactive::UnknownParamType`** (an `ArgumentError` subclass) at class
  load. The fix is to correct the typo or register the type
  (`Phlex::Reactive.param_type(:name) { |v| … }` in an initializer). This only
  affects schemas that were *already* silently mis-coercing; a valid schema is
  unchanged.

- **`on(:typo)` fails at render, not click (#105).** A misspelled or forgotten
  action used to render fine and only surface as an unexplained **403 on click**
  (the endpoint's default-deny). Now, when **`Phlex::Reactive.verbose_errors`** is
  on (the default in development and test via `Rails.env.local?`), **`on(:name)`
  raises `Phlex::Reactive::Error`** at **render** time if `:name` isn't declared
  on that component — the message lists the declared actions, the same loud-
  failure courtesy `reactive_compute_attrs` already gives an undeclared compute.
  You catch the typo the moment you load the page instead of hunting a mystery
  403.
  - **Production is unchanged.** With `verbose_errors` off (the production
    default) `on()` keeps today's permissive emit, so a stale page after a deploy
    that removed an action **never 500s on render**.
  - **Cross-component dispatch still works.** A component that declares **no
    actions of its own** — a child row rendering a trigger for its container's
    action and sending the container's token (e.g. a notification row → the list's
    `:dismiss`) — is skipped: it can't self-validate against a registry it doesn't
    own. `on_client` triggers are never checked (they aren't declared actions).
  - **Not the security boundary.** This is a dev-time aid; the server's
    default-deny stays the enforcement. The check is one flag-gated hash lookup
    with **zero added allocations** on the `on()`/render/token hot paths (measured:
    `on(:increment)` and `to_stream_replace` allocate byte-identically before and
    after; the prod path short-circuits on the flag before the lookup).

### Added

- **`reactive_text` mirrors + typed compute inputs (#104).** Mirror a form field
  into a **text node** — a live preview heading, a character counter,
  `"Hello, {name}"` — with **no round trip and no bespoke Stimulus controller**.
  Datastar's `data-text` / Alpine's `x-text`, but declared on the component.
  - **`reactive_text(:name, initial)`** renders `span(data: { reactive_text:
    name }) { initial }` — the **text sibling of `reactive_field`**. The client
    writes it via **`textContent`** (XSS-safe by construction, never `innerHTML`).
    It carries **no `name`**, so `#collectFields` never sweeps it into the POSTed
    params.
  - **Typed compute inputs.** `reactive_compute :x, inputs: { title: :string,
    qty: :number }, outputs:` types each input: a `:number` is coerced through
    `Number` (blank/NaN → 0), a `:string` reaches the reducer **raw** — so a live
    text preview reads real text, not `NaN`. The **array form** (`inputs: %i[a
    b]`) stays all-numeric and **byte-identical on the wire** (a JSON array); the
    hash form emits a JSON object of name→type.
  - **Output resolution.** A compute output whose name matches an owned form
    field writes that field's `.value` (the existing change-guarded `input`
    dispatch). An output with **no** matching field writes every owned
    `[data-reactive-text="<name>"]` node via `textContent` — change-guarded too,
    but **no** input dispatch (a text node has no listener contract).
  - **Reducer-less identity mirrors.** A separate always-run pass syncs each
    declared **input**'s raw value into its own `reactive_text(:same_name)` node
    on every keystroke — so `reactive_text(:title)` is a live field echo with **no
    registered reducer at all**.
  - **Seed the server render.** `view_template` must seed each mirror with the
    same derived value the reducer would, or a later morph repaints stale text —
    the same reconcile contract the new-vs-persisted split already documents.

- **Dirty-field tracking + unsaved-changes guard (#103).** Show "unsaved
  changes", enable **Save** only when something changed, or warn before navigating
  away — Livewire's `wire:dirty` — **without shipping any client state**. The
  browser already holds the last server-rendered value with zero extra bytes:
  `input.defaultValue` / `defaultChecked` / `option.defaultSelected` **are** the
  attributes from the last render, so **dirty = current ≠ default**, read straight
  from the DOM.
  - **`reactive_root(track_dirty: true)`** wires every input under the root to a
    full re-scan on change; **`reactive_field(:title, dirty: true)`** opts a single
    field in. On each change the client re-scans **every owned field in one pass**
    (the ownership guard excludes nested reactive roots) and marks each changed
    field `data-reactive-dirty="true"` and the root `data-reactive-dirty="<count>"`
    (**absent at zero**). The full pass — not a per-field toggle — is required for
    radio groups: the deselected radio fires no event, so only re-scanning
    everything keeps its flag honest. File inputs and `contenteditable` editors
    (no `default*` baseline) are out of scope in v1.
  - **CSS vocabulary, zero Ruby.** `[data-reactive-dirty] .unsaved-badge { … }`
    reveals a badge; `[data-reactive-dirty]` on a field outlines just the changed
    control — the same pure-CSS pattern as `[data-reactive-busy]`.
  - **Baselines reset on the server re-render.** A plain replace re-connects and
    re-scans in `connect()`; an in-place morph keeps the element connected and
    fires no Stimulus lifecycle, so a `turbo:morph-element` listener re-scans after
    the morph writes fresh `default*` attributes — a `reply.morph` save clears the
    markers with no reload. (`reactive:applied` fires *before* the DOM mutation, so
    it is **not** a valid reset hook and is deliberately not used.)
  - **`warn_unsaved: true`** arms a navigate-away guard gated on the **live** dirty
    count — `beforeunload` and `turbo:before-visit`; a clean form never blocks.
    Documented caveats: browsers show their own generic `beforeunload` copy, and
    `turbo:before-visit` does not fire on restoration (Back/Forward) visits.
  - Both `reactive_root` kwargs are **consumed before the `mix`** (otherwise an
    unconsumed kwarg would render as a literal HTML attribute); `track_dirty` and
    `dirty:` **token-join** their `input->reactive#trackDirty` descriptor onto any
    existing `data-action` (they don't clobber it), so combining with your own
    `data:`/`on(...)` still needs `mix(...)`.

- **Latency simulator dev aid — `PhlexReactive.enableLatencySim(ms)` /
  `disableLatencySim()` (#102).** On localhost the click→morph round trip is
  ~5 ms, so the pending/loading/optimistic affordances added in #98/#99/#100
  (`aria-busy`, `disable_with:`, `busy_on`, optimistic hints) flash by too fast to
  see while developing or demoing them — the reason LiveView ships
  `liveSocket.enableLatencySim(ms)`. Two named exports from the client controller
  (the `setConfirmResolver` precedent) persist a per-action delay to
  `sessionStorage` under `"phlex-reactive:latency"`; `#perform` reads it live
  right before the `fetch` — after the busy window has already opened at enqueue —
  and awaits it, so the affordances become observable. The delay is session-scoped
  (clears when the tab closes, so you can't leave it on across sessions), read
  fresh per request (toggling takes effect on the next action with no reload), and
  a one-time console banner reminds you while it's active.
  - **Console handle, dev-gated.** importmap module exports are unreachable from
    the DevTools console, so the bootstrap attaches
    `window.PhlexReactive = { enableLatencySim, disableLatencySim }` — but **only**
    when the app authored `<meta name="phlex-reactive-env" content="development">`.
    The meta is app-authored (the engine can't inject into the host layout); the
    install generator's initializer ships the commented snippet, and the README
    documents it. Without the meta there is **no global handle** and `#perform`
    short-circuits on the `null` `sessionStorage` read — **zero production
    surface**. This finally lets a system spec observe `aria-busy` in a real
    browser (previously impossible on a ~5 ms trip), under both Puma and Falcon.

- **Request timeout + offline handling — `reactive:error` kinds `timeout` and
  `offline` (#101).** A server that never responded used to wedge a component's
  request queue *forever* — each action chains on the previous one, so one hung
  `fetch` froze every future action and the `finally` that clears `aria-busy` /
  the loading state never ran. Going offline just fail-fast-looped each click as
  `kind: "network"`. Two mechanisms close this:
  - **Timeout.** The fetch is bounded by `AbortSignal.timeout(ms)` — default
    **30 s**, configurable via a page-authored `<meta name="phlex-reactive-timeout">`
    (same pattern as the action-path meta; no server setting). On abort it fires
    `reactive:error` `kind: "timeout"` (retriable) and the queue advances, so the
    component recovers. `AbortSignal.timeout()` rejects with a `TimeoutError`
    `DOMException` (NOT `AbortError`), correctly distinguished from a genuine
    network `TypeError` in the fetch catch.
  - **Offline.** A gate at the **network boundary** (`#perform`, send time — so a
    request that enqueued while online but reaches the wire after a drop is still
    caught) short-circuits when `navigator.onLine === false`: it fires
    `reactive:error` `kind: "offline"` (retriable) and never sends, so the edit is
    not half-sent. `data-reactive-offline` is mirrored onto `<html>` (kept in sync
    by the `online`/`offline` events) as a pure-CSS hook, zero app JS.
  - **Explicit non-goal:** no automatic replay. A timed-out POST may have
    succeeded server-side, so even manual `retry()` can double-apply a
    non-idempotent action — make retryable actions idempotent or gate retry UI.
- **User-visible failure surface — render error bodies, `error_flash`,
  `dismiss_after:` (#100).** A failing action used to show the user *nothing*:
  the client read a non-OK body only for the console and discarded it, the
  endpoint's rescue paths could log but not display anything, a network failure
  had no server to render, and flashes never cleaned themselves up. Four pieces
  close the gap, all opt-in and status-preserving:
  - **Client renders non-OK turbo-stream bodies.** When `!response.ok` but the
    Content-Type is a turbo-stream, the body is now applied (an `error_flash`, or
    a plain controller's `status: :unprocessable_entity` validation reply, is
    SHOWN). The root gets `data-reactive-error="<kind>"` (styleable in pure CSS),
    cleared on the next success. Token safety is preserved: a 400 body never
    refreshes the held identity token (`#extractToken` no-ops unless a stream
    re-renders this element's id).
  - **`Phlex::Reactive.error_flash`** (default `nil`) — a `->(kind) { "message" }`
    lambda. When set, every rescue path (400/403/404) renders a turbo-stream flash
    into `flash_target` at the **same status** it returns today. Composes with
    `verbose_errors`: the flash wins the response body, the diagnostic still logs.
    A lambda that raises degrades gracefully (falls back to the bare/diagnostic
    body — never a 500).
  - **Offline fallback** — a server-rendered `<template data-reactive-error-flash>`
    the client clones into the flash region on a `network` failure (trusted
    markup, cloned verbatim — no client templating).
  - **`dismiss_after:` on `reply.flash`** — `reply.replace.flash(:error, msg,
    dismiss_after: 4000)` self-removes the flash after the timeout via a
    **document-level** handler (so it self-cleans broadcast-delivered flashes too).
    Wraps string content; a verbatim Phlex component owns its own lifecycle.
- **Declarative loading states — `loading:` / `disable_with:` on `on(...)` +
  `busy_on(:action)` (#99).** Between the click and the morph the UI was fully
  live and unchanged: no per-trigger feedback, buttons stayed enabled, and a
  rapid double-click enqueued a full duplicate POST (the queue serializes tokens,
  it does not dedupe). This adds Livewire's `wire:loading` + `phx-disable-with`
  without a Stimulus controller. `disable_with: "Saving…"` disables the trigger
  and swaps its text while pending — and because a disabled button fires no
  further clicks, a double-click now enqueues exactly **one** POST (the disable
  is the dedup). `loading: { disable:, class:, text:, to: }` is the full form:
  a loading class on the trigger or a `to:` target, plus disable + text. Both
  apply at **enqueue** (covering the queue wait, not just the fetch) and revert
  on settle — **guarded** so a disconnected trigger is skipped and a
  server-rendered new label is never clobbered; the disable/text swap deliberately
  do NOT apply during a `debounce:` quiet period, so a debounced `input` is not
  disabled mid-typing. Independently, **every** round trip now carries an
  always-on busy vocabulary for the whole enqueue→settle window — no Ruby needed:
  `data-reactive-busy="<action>"` on the trigger and root (a **space-separated
  set** on the root so concurrent actions don't clobber), `aria-busy` on the root
  (via a **pending counter**, cleared only when the last request settles), and
  `busy_on(:action)` to scope `data-reactive-busy` onto a spinner only while that
  action is in flight. Style it with pure CSS (`[data-reactive-busy] .spinner { … }`).
  The trigger is now captured from `event.currentTarget` (not `event.target`), so
  a `<button><span>` click disables/relabels the button, not the inner span.
  Emitted as `data-reactive-loading-param` (JSON) via the guarded-append pattern,
  so the bare-`on()` hot path stays byte-identical. **`loading:` and
  `disable_with:` are now RESERVED keyword names on `on(...)`** — like
  `debounce:`/`confirm:`/`throttle:`/`optimistic:`, they can no longer be used as
  free action params.
- **`optimistic:` on `on(...)` — declared, reversible visual hints (#98).**
  Reactive interactions no longer wait a full round trip for their first visual
  change — and a checkbox no longer fails to flip at all (the client's
  unconditional `preventDefault` used to suppress the native flip until the
  morph). `optimistic:` applies a small, always-reversible, **cosmetic**
  vocabulary the instant the trigger fires and **reverts** it if the action
  fails — Livewire's "flip it client-side, let the morph correct". Supported
  hints: `toggle_class:`/`add_class:`/`remove_class:` (on the trigger, or a `to:`
  selector scoped to the root), `checked: :keep` (a click-bound checkbox/radio
  skips `preventDefault` so it flips natively now), and `hide: true`. Hints are
  visual only (never data, never client state), applied **once per flushed
  enqueue** (a debounced trigger can't flap per keystroke), and reverted from
  every failure branch (redirected/http/content-type/network + client apply),
  guarded by `isConnected`. On **success there is no cleanup**: a root re-render
  overwrites the hint with server truth, while a reply that does not re-render
  the root (`reply.remove`, streams-only) leaves it standing — that's the
  `hide: true` + `reply.remove` instant-delete recipe. Emitted as
  `data-reactive-optimistic-param` (JSON) following the guarded-append pattern of
  `debounce:`/`confirm:`/`throttle:`, so the bare-`on()` hot path stays
  byte-identical. **`optimistic:` is now a RESERVED keyword name on `on(...)`** —
  like `debounce:`/`confirm:`/`throttle:`/`listnav:`, it can no longer be used as
  a free action param.
- **`on_client(event, ops)` + the `js` op builder — client-side DOM commands
  with ZERO round trips (#95).** Purely-visual interactions (tabs, dropdowns,
  accordions, class toggles) no longer cost a signed server round trip or a
  hand-written Stimulus controller. `js` is an immutable, chainable builder of
  declared DOM operations — `show`/`hide`/`toggle` (the `hidden` attribute) and
  `add_class`/`remove_class`/`toggle_class` — and `on_client(:click, js.…)`
  binds them to a DOM event the ONE generic controller applies locally via a
  new `runOps` action: **no token, no params, no fetch, ever** (the system spec
  wraps `window.fetch` with a counter and asserts zero). The op vocabulary is a
  fixed whitelist mirrored client-side: an unknown op name warns and is skipped
  while the rest of the chain still applies (client-side default-deny —
  `Object.hasOwn`-guarded so inherited Object members can't masquerade as ops),
  and malformed ops JSON degrades to a no-op. Targets are CSS selectors
  resolved WITHIN the component's root — nested reactive roots are never
  touched (the issue-#15 ownership rule) — with `:root` for the root element
  itself and a per-op `global: true` document escape. `window:`/`once:`/
  `outside:` compose exactly like `on(...)`'s #80 modifiers (outside-click
  closes a dropdown; window-bound triggers never `preventDefault`). Builder
  validation is loud at render time (a non-selector target or an empty class
  list raises; `on_client` rejects a non-`Phlex::Reactive::JS` or empty chain)
  rather than silent in the browser. Client ops are EPHEMERAL UI by design: any
  server re-render resets them — the LiveView JS-commands caveat, documented in
  the README — so state that must survive a re-render stays a signed `action`.
  Same-machine `rake bench` before/after: the token/render/coerce hot paths are
  untouched (state-backed token 201k → within noise; allocations byte-identical
  at 11/47 per token, 113 per render) — `on_client` is a new, separate path.
- **`js` client ops: allowlisted attribute ops, focus, dispatch, and animated
  transitions (#96).** The client-only vocabulary from #95 grows to cover the
  interactions apps otherwise fall back to hand-written Stimulus for. New builder
  verbs: `set_attr(to, name, value)` / `remove_attr(to, name)` /
  `toggle_attr(to, name)` for attribute state (the value rides as a string, so a
  boolean flag is a real `"true"`, never a valueless attribute); `focus(to)` and
  `focus_first(to)` (the first focusable descendant of the match — the opened-menu
  → first-menuitem case); and `dispatch(name, to: nil, detail: {})`, a **bubbling
  `CustomEvent`** other components/controllers can react to (raw
  `element.dispatchEvent` — the shared controller SHADOWS Stimulus's `this.dispatch`
  helper). `show`/`hide`/`toggle` gain a `transition: [during, from, to]` keyword:
  the class lists are applied around the visibility flip and cleaned up on
  `animationend`, with a `setTimeout` fallback so a non-animated element never
  leaves them stuck and never hangs the chain (later ops run immediately —
  cleanup is fire-and-forget). The **attribute-name allowlist is the
  security-critical part, enforced on BOTH sides (two-sided default-deny)**: at
  build time in `js.rb` (an offending name raises `ArgumentError`) and again in the
  client interpreter (a forged/hand-built op is `console.warn`-ed and skipped, so
  it can't bypass the Ruby guard). Refused, case-insensitively: event handlers
  (`/\Aon/i` → XSS), the URL-bearing set (`href`, `src`, `srcdoc`, `action`,
  `formaction`, `xlink:href` → a `javascript:` navigation surface), and `style`
  (CSS injection). The intended surface — class ops plus `hidden`, `disabled`,
  `open`, `selected`, `aria-*`, `data-*` — is documented in the README. Covered by
  Ruby specs (each verb's JSON shape; the allowlist raises for every refused name,
  case-insensitively), bun tests (attr ops apply; the interpret-time allowlist
  warns + skips a forged op; focus lands; `dispatch` emits a bubbling event with
  detail; the transition swaps `from`→`to` on the next frame and cleans up on both
  `animationend` and the timeout fallback), and a system spec that opens a drawer
  with a real fade, sets `aria-expanded`, and focuses the first control under Puma
  AND Falcon. Refs #96.
- **`reply.js(...)` + `broadcast_js_to` — server-pushed DOM ops over a
  `reactive:js` stream action (#97).** The server can now tell the client to do
  something other than swap HTML — focus the next field after a save, dispatch an
  app event to a toast host, add an unread badge in every viewer's tab — WITHOUT
  re-rendering to make it happen. `Response#js(ops)` (surfaced on the reply facade
  as `reply.<verb>.js(ops)`) chains a `reactive:js` op stream onto ANY reply via
  the immutable `stream()` plumbing, and `Streamable.broadcast_js_to(*streamables,
  ops, exclude:, visible_to:, target:)` pushes the SAME ops to every subscriber of
  a stream over `Turbo::StreamsChannel` (Action Cable AND pgbus — transport opts
  pass through `broadcast_transport_opts` like every other broadcast). `ops` is a
  `js` chain (or a raw `[[op, args]]` array), interpreted by the SAME frozen
  `CLIENT_OPS` whitelist as `on_client` through a THIRD custom stream action
  (`registerReactiveJs`, a sibling of `reactive:visit`/`reactive:token`): an
  unknown op warns + is skipped (client-side default-deny). **The ordering contract
  is correctness-critical**: the op stream is emitted AFTER all render streams, so
  a `focus("[name=next]")` op sees the post-render/post-morph DOM (Turbo applies
  streams in document order) — a system spec proves focus lands on a freshly
  morphed field under Puma AND Falcon. **The broadcast builder REJECTS focus-class
  ops** (`focus`/`focus_first` → `ArgumentError`): broadcasting focus would steal
  it in every subscriber's tab, so focus is an actor-reply concern only. The ops
  attribute is HTML-escaped exactly like `to_stream_token` (a raw interpolation
  would be an injection vector), and `reactive:js` is NOT a self-render — it never
  trips `#extractToken` or `carries_token_for?`, so the reply's token refresh is
  untouched (pinned by a bun test and a request spec). Covered by Ruby specs
  (immutable chaining; ops-last ordering; escaping; the broadcast focus rejection;
  transport-opt pass-through with the pgbus-absent path unchanged), bun tests (the
  handler applies ops via the shared interpreter; `target` root scoping; token
  safety), a request spec (both streams in order with the token intact), and the
  focus system spec. Refs #97.

- **`on(...)` event modifiers — `window:`, `once:`, `outside:`, `throttle:`
  (#80).** Four trigger patterns that previously forced a hand-written Stimulus
  controller are now declarable on `on(...)`. `outside: true` fires the action
  only for events whose target is OUTSIDE the component's root — the
  close-a-dropdown-on-outside-click pattern; an event inside the root is a
  complete client-side no-op (bailing before `preventDefault` and before the
  `reactive:before-dispatch` lifecycle event). It implies `window: true`, which
  binds the trigger via Stimulus's native `@window` descriptor for page-level
  events (`scroll`/`resize`). Window-bound triggers are NEVER
  `preventDefault`-ed — a mounted dropdown must not kill native link clicks
  elsewhere on the page — and skip the forced `type="button"`; the client
  decides this from `data-reactive-window-param` (emitted as an explicit
  `"true"` string — Phlex renders a boolean `true` attribute VALUELESS, which
  Stimulus's param reader sees as `""`, falsy). `once: true` appends Stimulus's
  `:once` action option (fire at most once, then unbind). `throttle:`
  (milliseconds) rate-limits LEADING-EDGE — the first event fires immediately,
  further events are dropped until the window elapses — the mirror of
  `debounce:` (trailing-edge); passing both raises `ArgumentError`. Suppression
  timers are keyed on action + target (window scroll events all share
  `event.target === document`, so two window-bound triggers on one component
  must not collide) and torn down on `disconnect()`. The bare `on(:x)` emission
  is pinned byte-identical by spec — the four names become RESERVED `on(...)`
  kwargs, no longer usable as free action params.

- **Single include + a default `#id` for record-backed components (#81).**
  `include Phlex::Reactive::Component` now pulls in
  `Phlex::Reactive::Streamable` automatically (ActiveSupport::Concern's
  dependency mechanism includes Streamable into the base FIRST — exactly the
  manual order the old two-include ceremony established), so one include is
  enough; the legacy explicit double include remains a harmless no-op. And a
  record-backed component (`reactive_record :todo`) gets `#id` for free:
  `dom_id(record)` via the render-context-free `Streamable#dom_id` — the id
  virtually every such component wrote by hand. An explicit `def id` always
  wins (normal method lookup). Deliberately NO class-name default for
  state-backed components — they're frequently multi-instance, so a class-name
  id would silently collide; they (and bare Streamable classes) keep the loud
  `NotImplementedError`, now with a message that says how to fix it. Caveat:
  two different component classes rendering the SAME record on one page
  collide on the default — give one a prefixed id
  (`def id = dom_id(@todo, "rich")`). The component generator emits the new
  short form. Same-machine `rake bench` before/after: allocations on the
  render/token hot paths are byte-identical (192 obj per `to_stream_replace`,
  100 per `render_component`, 47 per record-backed token, retained 0) and
  throughput is unchanged within run-to-run noise — the default costs one
  `respond_to?` + two memoized reads, and only for components that didn't
  define `#id`.

- **`reactive_compute` reducers are told which field changed — one reducer can
  express a multi-way/mutual rebalance (#75).** A compute reducer now receives a
  second argument, `meta = { changed }`: the name of the declared input the
  triggering `input` event edited, or `null` (a direct `recompute()` call, or a
  target this root doesn't own / didn't declare as an input — nested reactive
  roots stay excluded per #15). That's exactly what the mutual-rebalance shape
  ("three fields that must always sum to a total") needs — given the same value
  snapshot, the reducer branches on WHICH field is the free/derived one:

  ```js
  setComputeReducer("three_way_split", ({ field_a, field_b, field_c, total }, { changed }) => {
    if (changed === "field_c") return { field_a: total - field_c - field_b }
    return { field_c: total - field_a - field_b }
  })
  ```

  Fully backward compatible: a one-argument reducer just ignores `meta` — no
  Ruby DSL change, no markup change. One contract to know: because an output
  write dispatches a real change-guarded `input` event (#76), `recompute`
  re-enters with `changed` = the OUTPUT field's name (when it's also a declared
  input), so a branching reducer must be **convergent** — the re-entrant pass
  must compute the values already in the DOM so the change guard settles the
  chain (the example above does: deriving `field_a` back from the just-written
  `field_c` reproduces its current value; no write, no event, settled in one
  bounce). Documented in `compute.js`'s header and the `reactive_compute` docs;
  covered by bun unit tests including the issue's three-way rebalance verbatim
  with a bounded reducer-call count.

- **`Phlex::Reactive.verbose_errors` — diagnostic endpoint error bodies +
  dropped-param logging (#82).** An endpoint failure used to be a bare
  `head 400/403/404` and a silently-dropped param left no trace — debugging
  "nothing happens" meant reading the gem source. Now every failure is
  warn-logged as `[phlex-reactive] …` in EVERY environment, and with
  `verbose_errors` on (default `Rails.env.local?` — development AND test; off
  in production) the response also carries a plain-text diagnostic body the
  client already prints via `console.error`: a tampered/stale token (400,
  distinguishing signature-invalid from a token class that no longer resolves
  from a class that isn't reactive — `InvalidToken` now carries a `diagnostic`),
  an undeclared action (403, listing the declared actions), a registered
  authorization error (403, naming the error class and the action), and a
  missing record (404, naming the GlobalID). Param coercion additionally logs
  every dropped key with its full bracketed path and reason
  (`undeclared` / `uncoercible`), hinting when a flat name looks like the
  bracketed twin of a declared nested key (the #16/#21 confusion). Statuses
  never change with the flag, the client needs no changes, and the production
  coercion path does zero extra work (nil collector, early-return guards) —
  `rake bench:one[coerce_params]` before/after is unchanged within noise

- **Client lifecycle CustomEvents — `reactive:before-dispatch` /
  `reactive:applied` / `reactive:error` with `retry()` (#79).** The generic
  controller now dispatches three bubbling, composed events around every action
  round trip, so an app can toast an error, veto a dispatch, instrument latency,
  or build retry UI without forking the one controller.
  `reactive:before-dispatch` is cancelable and fires once per user gesture —
  post-`preventDefault`, post-`confirm:`, PRE-debounce — with
  `{ action, params, element }`; `event.preventDefault()` skips the round trip
  entirely (nothing is scheduled, debounced or not). `reactive:applied` fires
  with `{ action, params, html }` after the fresh token was captured and the
  streams were handed to `Turbo.renderStreamMessage` (Turbo applies them
  asynchronously — listen to Turbo's own events for post-morph timing).
  `reactive:error` fires in every failure branch with
  `{ action, params, kind, status?, body?, retry? }` where `kind` is one of
  `redirected | http | content-type | network` (all retriable) or `apply` —
  the fetch itself succeeded and the server already completed the mutation,
  but something AFTER it threw INSIDE THE CONTROLLER (a malformed response, a
  Turbo render error — NOT a throwing `reactive:applied` listener, whose
  exception `dispatchEvent` never propagates back per the DOM spec, so it
  can't reach this catch); `apply` carries NO `retry` at all, since retrying
  would re-POST an action that already succeeded. `retry()`
  (when present) re-enters the request queue — re-reading the freshest signed
  token and re-collecting the fields at send time, refiring no second
  before-dispatch — and no-ops with a `console.warn` once the component left
  the DOM. Events go out via raw
  `dispatchEvent` (Stimulus's `this.dispatch` helper is shadowed by the
  controller's own `dispatch` action method) on the root element, falling back
  to `document` when a plain replace detached it; the existing `console.error`
  logging is unchanged. Composes with plain Stimulus listening —
  `data-action="reactive:error->toast#show"` on an ancestor. Covered by unit
  (JS) and real-browser system specs; README "Failure UX & lifecycle events"
  and the security docs page document the contract.

- **Combobox keyboard navigation — `on(:search, …, listnav: "[role=option]")` (#72).**
  A search/combobox trigger can now declare client-side list navigation: Arrow
  Up/Down move a highlight among the option elements IN-BROWSER (no round trip),
  Enter picks the highlighted option by clicking its own `on(:select)` trigger
  (so the selection stays a normal signed reactive action), and Escape clears —
  all without a bespoke Stimulus controller. `listnav:` appends Stimulus's native
  keyboard filters (`keydown.down/up/enter/esc->reactive#listnav*`) to the input's
  `data-action` and marks the option selector; the generic controller's `listnav*`
  handlers own the ephemeral highlight (a `data-reactive-highlighted` attribute,
  never shipped as trusted state), mirroring `#recompute`. Only the highlight is
  client-side — selection is still a default-deny, signed action. No new client
  module (the handlers live in the existing controller); covered by unit (JS),
  request, and real-browser system specs green under Puma AND Falcon.

- **Keyboard triggers on `on(...)` via `event:` — Enter-to-submit /
  Escape-to-cancel with no client JavaScript.** `event:` is interpolated straight
  into the Stimulus action descriptor, so **Stimulus's native keyboard filters
  just work**: `on(:add, event: "keydown.enter")` emits
  `keydown.enter->reactive#dispatch` and the action fires only on Enter, not on
  every keypress. `event: "keydown.esc"` gives Escape-to-cancel. No new option to
  learn (it's Stimulus's own filter syntax), no client change, no vendored-client
  re-sync — and, deliberately, **no reserved `key:` keyword**, so `key` stays a
  normal action-param name (`on(:switch, key: "pgbus")` keeps passing `key`
  through as a param — no backward-incompatibility). Because a keyboard trigger
  isn't a click, it does not get the `type="button"` a click trigger does. One
  action per element still holds — bind Enter-save and Escape-cancel to separate
  elements. README documents it under "Keyboard triggers".
- **`reactive_compute` — client-side data bindings (no round trip).** A component
  can now declare a client-side computation that recomputes derived fields
  IN-BROWSER on `input`, with NO server round trip — the "instant" half of a
  new/unpersisted-record UX that previously required a hand-written Stimulus
  controller (e.g. an order calculator that rebalances a payment split as you
  type). Declare the binding in Ruby and register the matching reducer once in JS:

  ```ruby
  reactive_compute :payment_split,
    inputs:  %i[allowance cash leasing total],   # fields the reducer reads
    outputs: %i[allowance cash leasing]          # fields it writes (no POST)
  # in the view: div(**mix(reactive_root, reactive_compute_attrs(:payment_split)))
  # on the edited field: data-action="input->reactive#recompute"
  ```

  ```js
  import { setComputeReducer } from "phlex/reactive/compute"
  setComputeReducer("payment_split", ({ allowance, cash, leasing, total }) => ({
    allowance, leasing, cash: total - allowance - leasing,
  }))
  ```

  The generic controller runs the named reducer on `input`, writes only the
  declared outputs (leaving the edited field + caret alone), and — for each
  output whose value actually changed — dispatches a bubbling `input` event on
  the field so a chained summary repaints, matching the server's `set_value` +
  `dispatch("input")` contract (see #76). A missing/unregistered reducer is a
  no-op (a page never breaks because a binding wasn't wired up). When the same
  component ALSO carries `on(...)` (a persisted record, or a draft you sync), that
  debounced POST still fires and the server reply reconciles — so `reactive_compute`
  is the optimistic client paint, the server round trip is the source of truth.
  One math contract, two execution sites. New client module
  `phlex/reactive/compute` (auto-pinned by the engine like `confirm`).

- **Draft (unpersisted-record) tokens — `reactive_record` no longer crashes on a
  `new_record?`.** A record-backed component may now render an UNSAVED record (an
  order the user is building before it's saved). `reactive_token` omits the `gid`
  when the record isn't persisted (`to_gid` would raise `MissingModelIdError`) and
  relies on the declared `reactive_state` as the draft seed, so the token still
  signs cleanly and the client controller mounts. The draft is driven client-side
  (`reactive_compute`) until it's saved; once persisted, a re-render signs the
  `gid` as before. Combined with `reactive_compute`, this is the "persisted → server,
  new → in-browser" split as a first-class capability instead of a hand-rolled one.

- **Overridable / async confirm resolver — reuse your themed dialog (#55).**
  Follow-up to #52. The `confirm:` gate was hardcoded to the synchronous,
  browser-native `window.confirm`, so a reactive trigger was the one interaction
  a Hotwire app couldn't theme — every confirmable reactive action showed the
  unstyled native chrome instead of the app's `Turbo.config.forms.confirm`
  dialog. The client now resolves the confirmation through an overridable hook
  (`confirmResolver`, set via `setConfirmResolver` from `phlex/reactive/confirm`),
  defaulting to `window.confirm`. An app reuses its styled dialog in one line:
  `setConfirmResolver((m) => window.Turbo.config.forms.confirm(m))`. The resolver
  may be **async** — `dispatch` `preventDefault`s up front (preserving the #11
  submit-trigger guarantee), then `await`s the resolver and enqueues only on a
  truthy result; a falsy resolve or a rejection cancels the action and never
  leaks an unhandled rejection. Unset, behavior is byte-for-byte identical to
  0.4.5 (sync native confirm, no dependency); the `confirm:` markup/`on(...)` API
  is unchanged. README documents the one-line opt-in.

- **`reactive_root` helper — the whole reactive root in one spread (#48).**
  `reactive_attrs` doesn't emit `id:`, so an app could put `id:` on a *child*
  element and leave the controller root's `id` empty — which silently re-opened
  the #46 add-once-only bug (the client falls back to the first token in the
  response, the next action POSTs a foreign token, and the endpoint 403s).
  `div(**reactive_root)` emits the component `id` **and** `reactive_attrs` on one
  element, so the id can't land on the wrong node; `reactive_root(class:, data:)`
  deep-merges via `mix`, and an explicit `id:` override still wins. `reactive_attrs`
  is unchanged — existing `div(id:, **reactive_attrs)` components keep working. The
  generic Stimulus controller now also `console.warn`s on `connect()` when a
  reactive root has an empty `id`, so the failure surfaces on page load (a one-line
  hint) instead of on the second click. README/docs promote `div(**reactive_root)`.

- **File / multipart params in a reactive action (#34).** An action can now accept
  an uploaded file: declare `params: { file: :file }` (or `[:file]` for multiple).
  When the reactive root holds a populated `<input type="file">`, the client sends
  the action as multipart `FormData` instead of JSON — `token` + `act` + scalar
  params as fields, the file(s) appended — and the endpoint coerces `:file` to the
  `ActionDispatch::Http::UploadedFile`, passed through untouched. A non-file value
  sent to a `:file` param is dropped (the keyword default applies), consistent with
  the #16 coercion rules — and for a `[:file]` array, a non-file *element* (a
  forged/mixed payload) is rejected from the array too, so the internal coercion
  sentinel never leaks to the action. A `<input type="file" multiple>` keeps its
  array shape (`params[name][]`) even when the user picks exactly one file, so a
  `[:file]` schema still coerces it. Token threading and the re-render/morph are
  identical; only the request encoding changes when a file is present — so
  attaching a document/receipt/image stays a reactive action instead of dropping
  out to a bespoke controller + upload Stimulus controller. Covered end-to-end:
  server coercion (request specs), the FormData wire shape (bun unit tests), and a
  real browser upload under Puma + Falcon (system spec).

### Documentation

- **Corrected the broadcast render-cost mental model — "N subscribers = N
  renders" was wrong (#78).** A `broadcast_*_to` call renders the component
  ONCE and passes the finished `html:` to `Turbo::StreamsChannel`, so every
  subscriber of that stream shares one payload (the per-subscriber cost is
  transport-side). The render cost is per CALL — broadcasting one change to K
  different stream keys is K builds + K renders + K token signings of
  byte-identical HTML — and per-viewer rendering (`visible_to:`-style content)
  is the irreducible render-per-viewer case. Fixed in the performance docs
  page, the render micro-bench comment, and CLAUDE.md; also repointed stale
  `docs/performance.md` references to the docs app's performance page
  (`docs/app/views/docs/pages/performance.rb`). No behavior changed.

- **The auto-collected-params contract, spelled out (#64, #65, #66, #67).** Four
  gaps surfaced from building one model-scoped form (numeric fields that rebalance
  live). No behavior changed — the README now documents what the code already
  does:
  - **#67** — a **flat** param schema silently drops **bracketed** field names.
    Because the endpoint expands `invoice[date]` to `{ "invoice" => { … } }`
    *before* matching the schema, a flat `{ date: … }` matches nothing and the
    action gets keyword defaults with no error. The "Model-scoped form fields"
    section now warns to nest the schema under the model key to match the names.
  - **#65** — auto-collected sibling fields are read **at dispatch time**, not
    from a pre-event snapshot: a `change`/`input` trigger sees its own new value
    and every peer's current DOM value. Documented in a new "Auto-collected
    sibling fields — the read contract" subsection.
  - **#66** — reactive collection **includes `disabled` fields**, deliberately
    unlike a native `<form>` submit, so a read-only computed field (a synced
    `total`) reaches the action. Documented as intentional, with the `readonly`
    vs `disabled` guidance for form-submit parity.
  - **#64** — a `reactive_record` action can use the record for **identity +
    authorization only** and compute over live, unsaved params, returning
    `reply.streams(...)` to stream a partial update with **no persist and no
    broadcast**. Documented as a first-class "record-authorized, transient-state
    action" pattern in the `reply` section.

  The demo app (`docs/`) gains a **live payment-split rebalancer** example — three
  amounts that always sum to a total, editing one rebalances the peers — that
  makes #64–#67 browsable (model-scoped bracketed params, a disabled computed
  field the action still reads, siblings collected at dispatch, transient compute
  with no persist/broadcast). The **todo** and **inline-edit** examples gain
  Enter-to-add / Enter-to-save / Escape-to-cancel via the new `key:` filter,
  covered by request specs and a real-browser (Playwright) Enter-keypress test.
  Combobox keyboard navigation is tracked separately (#72) for the
  minimal-client-seam work.

### Changed

- **Linter: Standard → RuboCop.** The gem now lints with RuboCop (all new cops
  enabled, `NewCops: enable`) instead of StandardRB, so the suite teaches and
  enforces newer Ruby idioms that Standard leaves alone — chiefly the Ruby 3.4
  `it` implicit single block parameter (`map { it.foo }`) via
  `Style/ItBlockParameter: always`. The whole tree was autocorrected; the
  lib/app changes were the `|x| x.foo` → `it.foo` rename plus hash-brace
  spacing — behavior is unchanged and all specs are green. The gemspec and
  Rakefile are excluded from `Style/ItBlockParameter` (their `do |spec| … end`
  config blocks read better named); a nested Phlex content block and a scope
  lambda carry inline disables where blanket `it` would collapse two parameters
  or break a `where(room:)` kwarg shorthand; and blocks that fed a
  keyword-argument shorthand (`Component.new(todo:)`) were rewritten to an
  explicit `Component.new(todo: it)` so the `it` rename can't silently change
  the keyword. Component-
  aware relaxations (line length, `Lint/MissingSuper`, unused action params)
  are scoped to `spec/dummy/app/components/**`. `bundle exec standardrb` is now
  `bundle exec rubocop`; `rake`'s default runs `spec + rubocop`.
- **Added `rubocop-capybara` and `rubocop-thread_safety`.** Capybara lints the
  browser specs (clean today — the suite already uses waiting matchers).
  thread_safety stays on as a tripwire for unsafe shared mutable state on the
  request/broadcast path; its `ClassInstanceVariable` /
  `ClassAndModuleAttributes` cops are scoped off only in the three files whose
  flagged class-level state is deliberate and audited — module-level config
  (`lib/phlex/reactive.rb`, set once at boot), class-definition-time DSL
  registries (`component.rb`), and the per-thread view-context cache's integer
  generation counter (`streamable.rb`). An adversarial audit confirmed none are
  request-path hazards; the lazy `||=` config defaults are idempotent. (A
  follow-up may warm `verifier`/`renderer` at boot to remove even the
  benign-by-idempotency first-call race — out of scope for this lint change.)

### Removed

- **Dropped the `standard` development dependency** in favor of `rubocop`,
  `rubocop-capybara`, `rubocop-performance`, `rubocop-rake`, `rubocop-rspec`,
  and `rubocop-thread_safety`.

### BREAKING

- **Minimum Ruby is now 3.4** (was 3.2). Enabling the `it` block parameter
  requires Ruby 3.4, so `required_ruby_version` is `>= 3.4.0` and the CI matrix
  drops 3.2 and 3.3. Stay on phlex-reactive 0.3.x if you need Ruby 3.2/3.3.

### Fixed

- **`reactive_compute` output writes never fired real `input` events — chained
  repaints were dead in production (#76).** The controller's `recompute()` wrote
  each output with a bare `field.value = …` under a comment claiming the write
  fires the field's `input` listeners. Only the bun-test fake's custom `value`
  setter did that — real browsers never fire `input` on a programmatic `.value`
  write — so anything listening on a computed field (a chained summary repaint,
  a second compute) silently never ran outside the test suite. The controller now
  dispatches a real bubbling `new Event("input")` after each output write, and
  the write is **change-guarded**: a field is written (and the event dispatched)
  ONLY when the reducer's value differs from the field's current value
  (String-compared). The guard is load-bearing, not an optimization — the shipped
  `payment_split` example declares overlapping inputs/outputs, so an
  unconditional dispatch would re-enter `input->reactive#recompute` forever;
  with the guard, chains settle deterministically (the re-entrant pass writes
  nothing and stops). The bun-test fake now matches real DOM (no auto-fire on
  `.value` assignment; listeners run only through the controller's explicit
  `dispatchEvent`), with unit coverage for the unchanged-write no-op, the
  single bubbling dispatch, loop termination on the payment_split shape, and a
  chained listener firing via the dispatched event — plus a real-browser system
  assertion that a derived field repaints after typing. The misleading comments
  in `reactive_controller.js` and `compute.js` now describe the real contract.

- **`reply.flash` discarded its level — `:error` and `:notice` emitted
  byte-identical streams (#77).** `Response.flash_stream` declared the level as
  `_level` and never used it, so an app could not style errors red without
  abandoning the flash helper — while the public API and every README example
  pass a level. String flash content is now wrapped in
  `<div class="reactive-flash reactive-flash--{level}"
  data-reactive-flash-level="{level}">…</div>`, so the level reaches the wire as
  a style hook (class) and a script/test hook (data attribute); the level is
  HTML-escaped before landing in either attribute. **This intentionally changes
  the wire output for string flashes** (previously the bare string was appended
  with no wrapper) — restyle against `.reactive-flash--{level}` if you targeted
  the raw text node. The string itself keeps the exact pre-existing injection
  contract, now applied inside the wrapper: a plain String is HTML-escaped, an
  `html_safe` String passes verbatim. Phlex **component** content still renders
  VERBATIM — byte-identical to before, no wrapper (the caller owns the markup;
  a spec pins it). New config `Phlex::Reactive.flash_component = MyFlash`
  (default nil) renders string flashes through your own component instead of
  the default wrapper — instantiated `MyFlash.new(level:, content:)` and
  rendered through the existing render path; component content bypasses it.

- **`reactive_controller.js` used a relative `./confirm.js` import that 404'd under
  importmap-rails + Propshaft — taking down every Stimulus controller on the page (#57).**
  The #55 confirm resolver added `import { confirmResolver } from "./confirm.js"` to the
  client controller. Under importmap + Propshaft the controller is served at its
  **digested** URL, and a relative sibling import is left untouched (Propshaft's JS
  compiler rewrites only `RAILS_ASSET_URL(...)`, and the import map resolves **only**
  bare specifiers, never relative-resolved URLs). So the browser resolved `./confirm.js`
  against the digested controller URL and requested an **undigested**
  `/assets/phlex/reactive/confirm.js` → **404**. The throwing import meant
  `reactive_controller.js` never evaluated, and in an app that eagerly registers it the
  whole controllers entrypoint died — **every** Stimulus controller on the page stopped,
  with no obvious link to phlex-reactive. The fix imports the **bare** specifier the
  engine already pins (`phlex/reactive/confirm`), which resolves to the digested asset
  through the import map and mirrors how the gem already expects apps to import the
  module (`import { setConfirmResolver } from "phlex/reactive/confirm"`). Bundlers
  (esbuild/webpack/bun) resolve the bare specifier the same way they already resolve
  `phlex/reactive/reactive_controller`; the gem's bun JS suite resolves it via a new
  `tsconfig.json` `paths` alias. Covered by a bun unit test (the bare import resolves,
  and the source no longer carries the relative form). 0.4.5 was unaffected (inline
  `window.confirm`, no relative import).

- **Client mirror of #44: collections of *reactive* rows were STILL add-once-only in
  the browser — `#extractToken` read the FIRST token in the response, not this
  controller's own (#46).** The server fix in 0.4.2 (#44) made the `add` response
  correct — the container's fresh `reactive:token` stream is present — but the
  client still broke. After each action the reactive controller stores the
  response's fresh token for its NEXT dispatch; `#extractToken` did
  `html.match(/data-reactive-token-value="([^"]+)"/)` — the FIRST match in the whole
  body. On a collection of reactive rows the response is, in body order: the
  appended/prepended ROW (carrying its OWN token, since a reactive row is itself a
  `data-controller="reactive"` root) FIRST, then the container's `reactive:token`
  refresh LAST. So the list controller stored the ROW's token; its second dispatch
  sent a row token → failed verification → the second add silently did nothing. The
  fix reads the token that RE-RENDERS this controller's own element id — preferring
  the dedicated `reactive:token` stream targeting `this.element.id`, then a self
  `replace`/`update` of it — and otherwise keeps the existing token (never adopting
  a child row's or a sibling component's token). This is the exact client analogue
  of the #44 server rule: a stream "carries the token for C" only when it re-renders
  C itself, never when it inserts children into C. A request-level test can't catch
  this (the server response is already correct); covered by a bun unit test on the
  token selection AND a real two-click browser test (a collection of reactive rows →
  three rows after three adds) under Puma + Falcon. Refs cosmos#1939, #44, #30.

- **Collections of *reactive* rows were still add-once-only — a prepended/appended
  row's OWN token suppressed the container's token refresh (#44).** When an action
  appended/prepended a *reactive* child row into a container whose `#id` equals the
  append target (the most common collection shape — rows go directly into the
  container element), that single `append`/`prepend` stream carried BOTH
  `target="<container>"` and the row's own `data-reactive-token-value` (embedded in
  the `<template>`). `carries_token_for?` matched
  `include?("data-reactive-token-value") && include?(target)` in that one string →
  both true → it concluded the container's token was already fresh and **skipped**
  the container's `reactive:token` refresh. So the container (which owns the
  add/remove trigger) never rolled its token forward, and the second dispatch was
  rejected with the stale token — the list silently stopped after the first add.
  This hit both the hand-rolled `reply.streams(Row.prepend(...), …)` form **and**
  the `reactive_collection` / `reply.append`/`reply.prepend` helper, since they
  share the gate. Fixed by tightening `carries_token_for?`: a stream "carries the
  token for C" only when its action RE-RENDERS C itself (`replace`/`update`/
  `reactive:token` at C's target) — `append`/`prepend` (which insert *children*
  into C) never count, because a reactive child's token is not the container's. The
  idempotency the gate provided is preserved (a caller's own self-replace still
  suppresses the duplicate token) and the #30 sibling case still refreshes
  correctly. Covered at the request level: a reactive row appended twice in a row
  (the second using the token the first rolled forward) now succeeds, and each
  response carries a `reactive:token` stream targeting the container with a
  non-empty token. Refs cosmos#1939, #35, #30.

- **0.4.0 regression: re-renders lost the `request`, crashing `form_authenticity_token`
  and other request-dependent helpers (#42).** The 0.4.0 render-path perf rework
  built the cached off-request view context from a bare
  `ActionController::Base.new.view_context`, whose controller has `request == nil`.
  Any reactive component whose `view_template` calls `form_authenticity_token`,
  `protect_against_forgery?`, or a host-aware URL helper (all of which read
  `request.env`) then raised `NoMethodError: undefined method 'env' for nil` on
  **every** re-render — through the action endpoint AND on broadcasts — so any app
  with a reactive component rendering a Rails CSRF form could not adopt 0.4.0. Fixed
  by building the cached view context through a request-bound controller
  (`Phlex::Reactive.request_bound_view_context`), replicating exactly what
  `ActionController::Renderer#render` does to set up its mock request: an
  `ActionDispatch::Request` whose host is derived from the routes'
  `default_url_options`. The 0.4.0 `render_in` speedup is kept — the request is set
  up once when the per-thread context is built (not per render), and steady-state
  render throughput/allocations are unchanged (retained-per-render stays 0). Covered
  at the request level (a reactive `save` re-rendering a CSRF form returns 200, not
  500), the broadcast level (the form component broadcasts without crashing), and the
  unit level (a request is present on the cached context; host-aware `*_url` helpers
  resolve when the renderer carries routes).

- **Multipart path silently dropped an explicit nested-hash / array param (#39).**
  When an action declared a `:file` param alongside an explicit nested (hash/array)
  param, the nested param was dropped on the multipart path while the JSON path
  handled it correctly — the two encodings were asymmetric. The client's
  `#buildFormData` `JSON.stringify`'d a non-scalar param into one
  `params[key]='<json>'` field, which the server received as an un-decodable
  `String` leaf and dropped (nested hash → `{}`, array → key removed). Fixed
  client-side: `#buildFormData` now bracket-expands a nested object/array into
  `params[key][sub]` / `params[key][index][...]` fields (arrays use numeric
  indices) — the same Rails-form shape the server's `expand_bracket_keys` /
  `array_values` already parse, so a JSON body and a multipart body now coerce
  identically. The server is unchanged. One intentional divergence: an empty
  array/object as a whole param can't be carried by `FormData`, so the multipart
  path omits the key (the action's keyword default applies) rather than sending an
  explicit-clear `[]`/`{}`. Covered end-to-end: the bracketed multipart shape
  coerces correctly (request specs), a `:file` alongside a nested param both
  survive (request spec), and the FormData wire shape (bun unit tests).

- **`to_stream_token` emitted an EMPTY token, making non-self-rendering replies
  add-once-only (cosmos#1939).** `Streamable#to_stream_token` guarded on
  `respond_to?(:reactive_token)`, but `Component#reactive_token` is **private**, so
  the guard was false for every component and the refresh stream carried
  `data-reactive-token-value=""`. Any reply that opts out of the full-self replace
  but relies on the token-only refresh — `reply.streams` (#30) and the new
  `reply.append`/`reply.remove` (#35) — therefore rolled an empty token forward:
  the first action worked, then the next dispatch from that root was rejected (the
  stale/empty token fails verification) with no error. Fixed by checking private
  methods (`respond_to?(:reactive_token, true)`); a bare Streamable (genuinely no
  token) still skips correctly. The `reactive_collection` builders also now bind the
  **container** as the `token_component`, so an add/remove rolls the list root's
  token forward (the load-bearing part for repeated add/remove). Regression tests
  assert the token is non-empty AND re-verifies, and that a second add using the
  first reply's token succeeds.

### Changed

- **The browser suite now runs under two real servers — Puma and Falcon.** The
  `system` CI job runs as a matrix (`CAPYBARA_SERVER=puma` and `=falcon`), and a
  new `rake spec:system_servers` task runs both locally, so a reactive round trip
  is proven transport-agnostic across a sync (Puma, thread-pool) and an async
  (Falcon, fiber-per-request) server. `webrick` is **removed** as a test server
  (it isn't a real server) — `falcon` (with `protocol-rack`) replaces it as the
  alternative, registered via `Capybara.register_server(:falcon)`. No production
  dependency change; this is test infrastructure only.

- **CI now tests against Ruby 4.0** (added to the test matrix in `main.yml` and
  the pre-release matrix in `release.yml`, alongside 3.2/3.3/3.4; the lint and
  browser-system jobs also run on 4.0 now). Ruby 4.0 shipped December 2025 and is
  the current stable line. The gem requires no code changes for 4.0 — its
  dependencies and the patterns it uses (ObjectSpace::WeakMap, Data.define,
  Thread-locals, the MessageVerifier path) are stable across 3.4 → 4.0, and it
  directly requires none of the gems 4.0 moved from default to bundled.
  `required_ruby_version` stays `>= 3.2.0` (no upper bound, already permits 4.0).
  Verified empirically: the full unit/request/generator suite is green on Ruby
  4.0.5 with zero deprecation or unbundled-gem warnings.

### Added

- **`reactive_collection` — add/remove-row lists in one declaration (issue #35).**
  An add/remove-row list (line items, tags, comments, a notifications list) is one
  of the most common reactive surfaces, and every one re-implements the same
  orchestration by hand: append the row to the right container, remove it on
  delete, keep a count badge in sync, and swap an empty-state in/out as the list
  crosses 0↔1. `reactive_collection :items, item:, container:, count:, empty:,
  size:` declares that contract **once** on the container component, so each action
  is a single call: `reply.append(:items, model)` (row + count + empty-state
  clear), `reply.prepend(:items, model)`, and `reply.remove(:items, model_or_id)`
  (row + count + empty-state restore). The size badge and empty-state toggle are
  driven by the declared `size:` resolver, **re-counted server-side after the
  mutation** — so they're correct-by-construction (no off-by-one, no client-held
  count, consistent between the first render and the deltas). `count:`/`empty:`/
  `size:` are optional (omit them and only the row stream is emitted), and the new
  builders compose with `.flash`/`.stream` like any other reply. Reply governs the
  actor's HTTP response only; a cross-tab live list still broadcasts the row with
  `broadcast_append_to(..., exclude: reactive_connection_id)`. New
  `Phlex::Reactive::Component::CollectionDefinition`,
  `reactive_collection`/`reactive_collection_def`/`reactive_collection?` macros,
  and `Response.collection_append`/`collection_prepend`/`collection_remove` behind
  the `reply.*` surface.

- **`reply.streams` — partial update with a token-only refresh (issue #30).**
  `reply.streams(Totals.update(@item))` emits **exactly** the streams you pass —
  no forced full-self replace — so an action can re-render only part of a
  component (one total cell, one sub-region) while the rest of the DOM, including
  a sibling `<input>` the user is mid-typing in, is left untouched. The signed
  identity token still rolls forward: the endpoint appends a tiny
  `<turbo-stream action="reactive:token">` (new `Streamable#to_stream_token`) that
  carries the fresh `data-reactive-token-value` and is applied by an inert client
  action — a pure attribute write on the root, so the focused field + caret
  survive. This unblocks spreadsheet-like per-field grid editing that the old
  "every reply re-renders the whole component" behavior made unusable (you had to
  reach for `data-turbo-permanent`). `Response.streams(self, *)` is the underlying
  builder; `reply.streams(*)` is the bound form. Backed by a new `render_self:
  false` + `token_component` path in the endpoint — the legacy full-self-replace
  refresh (`reply.replace` / `reply.with`) is unchanged.

- **`reply` — the action-reply builder.** Control an action's reply with
  `reply.replace` / `reply.morph` / `reply.update` / `reply.remove` /
  `reply.redirect(url)` / `reply.with(*)`, chaining `.flash` / `.stream` /
  `.also_update` / `.also_replace` as before. `reply` is a subject-bound facade on
  the component, so the two warts of the old form disappear: no `self` to thread
  (`reply.morph`, not `Response.morph(self)`) and no constant to qualify — a
  namespaced component no longer needs a per-file `Response = …` alias, because
  `reply` is a method resolved on the component, not a lexical constant. It
  returns the same immutable value object the endpoint reads, so the return-value
  contract, immutability, and chaining are unchanged. `Phlex::Reactive::Response`
  remains fully functional but is now an internal detail — `reply` is the
  documented surface.

- **Morph response — focus-preserving re-render (issue #28).**
  `reply.morph` (and the opt-in `reply.replace(morph: true)`)
  re-renders a component in place via Turbo 8's bundled Idiomorph
  (`<turbo-stream action="replace" method="morph">`) instead of an outerHTML
  swap. The focused `<input>` and its caret survive the save, making per-field
  reactive editing — a "spreadsheet" grid where a debounced save fires while the
  user is still typing/tabbing — actually viable. Backed by the new
  `Streamable#to_stream_morph` primitive and a `morph:` flag on the
  `.replace` / `.broadcast_replace_to` class builders and `#also_replace`
  (live cross-tab updates can morph too). The default everywhere stays the plain
  replace (no `method="morph"` attribute), so existing components are unchanged.
  No new dependency — Idiomorph ships with `turbo-rails >= 2.0`.
- **Input/select param-binding helpers (issue #23).** `reactive_input(:value,
  …)` and `reactive_select(:status, …) { … }` render a form control already bound
  to an action param — no hand-written `name: "value"` magic string to forget
  (which silently leaves the action with no params). `reactive_field(:param,
  **attrs)` returns just the attribute hash to spread onto any control; an
  explicit `name:` still wins as an escape hatch. The trigger stays on the
  button, so focusing the field doesn't dispatch and collapse edit mode.
- **`accepts_nested_attributes_for` helper (issue #24).** `nested_update!(:address,
  address)` maps a declared nested param straight onto `<assoc>_attributes` and
  carries the existing associated record's id, so `update_only:` matches it in
  place instead of building a second `has_one` — replacing the per-editor
  `*_attributes` + id-preservation boilerplate that was easy to get subtly wrong.
  `nested_attributes(:address, address)` returns the id-merged hash without
  updating, for combining with other attributes.
- **`Response#also_update` / `#also_replace` (issue #25).** Re-render a companion
  element alongside self without dropping to raw `turbo_stream_builder`:
  `Response.replace(self).also_update("page_heading", html: @record.name)` adds an
  update stream for an arbitrary DOM id (`html` is a string or a Phlex component,
  rendered through the configured renderer), and `.also_replace(other_component)`
  re-renders another Streamable component targeting its own `#id`. Both are
  immutable and additive, so the self-replace still refreshes the signed token.
- **Boot-time integration guards (issue #26).** Two silent first-run failures now
  surface a clear warning. A host catch-all route (`match "*path", …`) that
  shadows the engine's appended `POST /reactive/actions` (every reactive POST
  404s) is detected at boot via a route-recognition check
  (`Phlex::Reactive.action_route_ok?`), logging how to exempt the path. And when
  `data-controller="reactive"` elements are on the page but no controller
  connected — the `lazyLoadControllersFrom` case where the gem's controller was
  never registered — the client runtime logs a console warning naming the fix.
  The README gains an "Integration troubleshooting" section covering both.
- **Nested & array param types (issue #16).** Action param schemas can now
  declare arrays and nested hashes, not just scalars: wrap a type in an array
  (`bank_account_ids: [:integer]`) for an array param, or wrap a hash schema in
  an array (`invoice_items_attributes: [{ id: :integer, quantity: :float,
  _destroy: :boolean }]`) for Rails-style nested attributes. Coercion recurses
  per field, drops undeclared nested keys (no mass assignment), and accepts an
  array as either a JSON array or a Rails index hash (`{ "0" => …, "1" => … }`).
  A malformed (present-but-non-array) value for an array param is dropped — not
  coerced to `[]` — so a bad payload can't read as an explicit "clear all" on an
  `update!(declared_array:)`; a real empty array still passes through as `[]`.
  A reactive form can now mirror a normal nested-attributes update in one action
  instead of being forced into a per-row component architecture.
- **Debounce option on `on(...)` (issue #17).** A trigger can declare
  `on(:update, event: "input", debounce: 300)` (milliseconds) to coalesce rapid
  events — typically keystrokes — into a SINGLE action round trip fired after the
  quiet period, instead of one POST per keystroke. A `blur` flushes a pending
  dispatch so the last edit is never dropped, `preventDefault` still fires
  synchronously (a debounced `submit` won't navigate), and the debounced round
  trip still goes through the per-component queue so token threading holds.
  Omitting `debounce:` keeps the immediate-dispatch default.

### Performance

- **Re-render is ~2× faster with ~half the allocations.** `render_component` now
  renders through phlex-rails' lightweight `#render_in` against a memoized
  off-request view context, instead of `ActionController.renderer.render` (which
  dragged in ActionView's `TemplateRenderer`/`LookupContext`/log subscriber).
  Measured same-machine before/after: `render_component` 6.99k→14.1k i/s (212→99
  obj/call); `to_stream_replace` 4.60k→8.00k i/s (331→191 obj/call). HTML is
  byte-identical and the full Rails helper set (`dom_id`/`url_for`/`t`/CSRF) still
  works. The biggest win is on the **broadcast** path (N subscribers = N renders,
  no HTTP to amortize against); at the full-request level the Rails stack + DB
  dominate, so request throughput is roughly unchanged.

- **View context, Turbo `TagBuilder`, and flash builder are memoized** per
  component class (the comment used to claim this; now it's true). Keyed on the
  configured renderer's identity so swapping `Phlex::Reactive.renderer` rebuilds,
  and reset on Rails code reload (`config.to_prepare`) so a reloaded controller
  is never served stale.

- **Smaller per-render allocations on the token path.** `reactive_token`
  precomputes its ivar symbols + state string-keys per class (14→11 obj/call,
  state-backed), and `on(:action)` skips re-serializing an empty params hash
  (6→5 obj/call). The bracket-key regex in param coercion is hoisted to a frozen
  constant.

- **Client: the page-stable action path is resolved once per controller** instead
  of a `querySelector` per dispatch. CSRF token and pgbus connection id stay live
  (they can rotate).

- **Benchmark harness + CI report.** `rake bench` (micro: render/token/coerce) and
  `rake bench:request` (end-to-end via derailed) measure the hot paths; a CI
  `bench` job runs them on every PR and uploads the report as an artifact
  (run-and-report, not a hard gate). See `docs/performance.md` and the `/perf`
  command.

### Fixed

- **Model-scoped form fields feed a nested param (issue #21).** A Rails
  `Form(model: @invoice)` posts flat bracketed keys (`invoice[date]`,
  `invoice[status]`) because the client keeps each input's `name` verbatim. The
  server did exact-key matching, so a nested schema (`params: { invoice: { date:
  :string } }`) looked for the literal key `"invoice"`, never found it, and
  dropped the whole param. Param normalization now expands bracket notation
  before coercion — `invoice[date]` nests under `invoice`, and
  `items_attributes[0][qty]` becomes the Rails index-hash form the array coercer
  already understands. A nested schema matches a normal Rails form with zero
  field renaming, which is what makes the issue #16 nested-param types useful for
  real forms. Pre-nested objects, plain scalars, and non-string values (a
  checkbox boolean) pass through unchanged.
- **Nested reactive roots no longer leak fields (issue #15).** When a reactive
  component is rendered inside another (both are `data-controller="reactive"`
  roots), an action on the outer root previously swept *every* descendant named
  input — including the nested roots' inputs — into its own params. Field
  collection now stops at nested reactive roots: an action collects only the
  inputs whose nearest `[data-controller~="reactive"]` ancestor is its own root.
  Outer flat fields and per-row reactive editing compose cleanly, with no
  name-disjointness workarounds.

## [0.2.6]

### Added

- **Action response control via `Phlex::Reactive::Response`.** An action MAY now
  return a `Response` to govern the actor's HTTP reply, instead of only the
  implicit single re-render. Returning anything else keeps the legacy default
  (re-render the component in place), so existing actions are unaffected.
  - `Response.replace(self)` / `.update(self)` — explicit re-render.
  - `Response.replace(self).flash(:error, msg_or_component)` — surface a
    validation error / notice (the `#1` driver). `.flash` is additive on a
    self-replace, so the component's signed token always refreshes. Flash
    content is supplied explicitly (the render context is off-request — there is
    no Rails `flash`); pass a string or a Phlex component. Target container is
    `Phlex::Reactive.flash_target` (default `flash`).
  - `Response.remove(self)` — drop the element (e.g. a moderation queue). New
    instance helper `Streamable#to_stream_remove` backs it.
  - `Response.redirect(url)` — client-side `Turbo.visit` for when the current
    URL is dead (e.g. a slug rename). Rides a 200 turbo-stream carrying a
    `reactive:visit` custom action (registered in the client), **not** an HTTP
    3xx (which the client bails on). Pass a `*_url`.
  - `Response.with(*streams)` / `#stream(*more)` — multi-stream (replace self +
    a sibling component).
- The endpoint guarantees the component's own replace is present (token refresh)
  for non-remove/redirect responses, and never double-prepends when the action
  already included a self-targeted stream.

## [0.2.5]

### Fixed

- **Form submit navigated instead of running the reactive action.** A component
  wired with `on(:save, event: "submit")` on a real `<form>` let the browser
  submit natively (full POST to the form's `action`), because
  `dispatch()` deferred `event.preventDefault()` into the request-queue microtask
  — too late, since `preventDefault()` only works synchronously within the event
  dispatch. For `click` triggers there's no default to miss, so it was invisible;
  for `submit` the form navigated (e.g. `POST /` → routing error). `dispatch()`
  now calls `preventDefault()` synchronously (and captures the action/params up
  front, so the deferred work never re-reads a reset event object). Guarded by a
  bun unit test (`spec/javascript/reactive_controller.test.js`) that asserts the
  synchronous call and fails on the pre-fix deferred code. Closes #11.

## [0.2.4] - 2026-06-24

### Fixed

- **Reactive save silently dropped rich-text / custom-editor fields.** The
  client's field auto-collection (`#collectFields`) queried only
  `input[name], select[name], textarea[name]`, so a named rich-text editor
  (`lexxy-editor`, `trix-editor`) or any `[contenteditable]` was skipped — a
  reactive `save` posted an empty value and silently wiped the field, with no
  error. `#collectFields` now also reads named custom editors and contenteditable
  elements (by `name` *attribute*, since a plain element has no `name` IDL
  property), reading the serialized `.value` else the contenteditable text. It
  only fills a name the standard controls left absent or empty, so a hidden input
  a rich editor mirrors into (e.g. Trix) still wins when populated. The vendored
  client copy the system suite runs (`spec/dummy/public/vendor/...`) is now kept
  byte-identical to source by a guard spec, so the browser tests never validate
  stale client code again. Closes #8.

## [0.2.3] - 2026-06-24

### Fixed

- **Record-backed components silently lost `reactive_state` every action.** When
  a component declared BOTH `reactive_record` and `reactive_state`, the state
  branch was dead: `reactive_token` signed only the record GID and
  `from_identity` rebuilt with only the record — so the listed instance vars
  (e.g. `attribute`, `editing`) reset to their `initialize` defaults on every
  action. This broke the documented `inline_edit` example (clicking "edit"
  couldn't stay in edit mode; `save` wrote the wrong/blank column) and quietly
  voided the docs' promise that `@attribute` is signed/tamper-proof.
  `reactive_token` now signs the record GID AND the declared state into one
  `MessageVerifier` payload, and `from_identity` restores both — record + state
  are composable, and the state stays tamper-proof. Record-only (`{c, gid}`) and
  state-only (`{c, s}`) token shapes are unchanged; a signed `false` survives the
  round trip (only a genuinely absent value falls back to the `initialize`
  default). No API changes. Closes #6.

### Documentation

- Documented the combined record + state identity (the `{c, gid, s}` token
  shape): the README, `docs/architecture.md`, and `docs/security.md` no longer
  frame `reactive_record` and `reactive_state` as mutually exclusive. (#9)

## [0.2.2] - 2026-06-24

### Fixed

- **Record-backed component built with a different init keyword by the action
  endpoint vs the broadcast path.** The click path (`Component.from_identity`)
  builds with `reactive_record_key` (the `reactive_record :name`), but the
  broadcast path (`Streamable.build` → `model_param_name`) built with the
  demodulized, underscored class name. They only agreed when the class name
  happened to equal the record name — otherwise one path worked and the other
  raised `ArgumentError: missing keyword`. The README's own `Todos::Item`
  (`reactive_record :todo`, `Item` ≠ `todo`) hit this on broadcast.
  `model_param_name` now prefers `reactive_record_key` when set, so a single
  `initialize(<record>:)` satisfies both clicks and broadcasts. `Streamable`-only
  components (no `reactive_record`) keep the demodulized-class-name default, and
  an explicit `def self.model_param_name` override still wins. No API changes.
  Closes #4.

## [0.2.1] - 2026-06-24

### Fixed

- **Zeitwerk eager-load crash in host apps.** A host app with
  `config.eager_load = true` (the production default) runs
  `Zeitwerk::Loader.eager_load_all`, which walked this gem's loader and raised
  `Zeitwerk::NameError` on two files that don't follow Zeitwerk's
  file→constant rule: `version.rb` (defines `VERSION`, not `Version`) and the
  Rails generators under `lib/generators` (whose path/constant scheme is
  intentionally non-Zeitwerk). The loader now requires `version.rb` up front and
  ignores it, and ignores `lib/generators` (Rails loads generators itself), so
  the gem eager-loads cleanly. Added a regression spec that calls
  `eager_load_all`. No API changes.

## [0.2.0] - 2026-06-24

### Added

- **Actor-echo suppression.** `broadcast_*_to` now accepts `exclude:` (and
  `visible_to:`), forwarded to the stream transport. Pass
  `exclude: reactive_connection_id` from an action so the actor doesn't receive
  the echo of its own broadcast — making `append`/`prepend` and optimistic UI
  safe. The client sends its SSE connection id as `X-Pgbus-Connection`; the
  endpoint exposes it via `Phlex::Reactive.current_connection_id` /
  `reactive_connection_id`. Honored by pgbus; ignored (harmless) on Action Cable.

### Requires

- **pgbus >= 0.9.4** when using `exclude:`/`visible_to:` — it ships the
  `exclude:`/`visible_to:`/`event:` forwarding through Turbo's broadcast
  helpers. phlex-reactive still works on Action Cable without pgbus; the
  `exclude:` argument is simply ignored there.

## [0.1.0] - 2026-06-20

### Added

- `Phlex::Reactive::Streamable` — class methods (`replace`, `update`, `append`,
  `prepend`, `remove`) and broadcast methods (`broadcast_replace_to`, ...) that
  render a Phlex component as an auto-targeted Turbo Stream by its stable `id`.
- `Phlex::Reactive::Component` — declare client-invokable `action`s with a param
  schema; `reactive_record` (record-backed, GlobalID identity) and
  `reactive_state` (record-less, signed state); `reactive_attrs` and `on(...)`
  view helpers.
- `Phlex::Reactive::ActionsController` — one signed-identity endpoint behind all
  reactive components; default-deny actions, schema-coerced params,
  transactional action execution.
- Generic `reactive` Stimulus controller — per-component request serialization,
  synchronous token threading, auto field collection; no per-feature controllers.
- Rails engine — mounts the action endpoint, registers and auto-pins the client
  runtime for importmap apps.
- **Generators.** `rails g phlex:reactive:install` registers the `reactive`
  Stimulus controller (eagerly) and writes a config initializer.
  `rails g phlex:reactive:component Name [actions] [--record name | --state vars]`
  scaffolds a reactive component (and an RSpec spec when the app uses RSpec),
  state-backed by default or record-backed with `--record`.

[Unreleased]: https://github.com/mhenrixon/phlex-reactive/compare/v0.9.0...HEAD
[0.9.0]: https://github.com/mhenrixon/phlex-reactive/compare/v0.2.6...v0.9.0
[0.2.6]: https://github.com/mhenrixon/phlex-reactive/compare/v0.2.5...v0.2.6
[0.2.5]: https://github.com/mhenrixon/phlex-reactive/compare/v0.2.4...v0.2.5
[0.2.4]: https://github.com/mhenrixon/phlex-reactive/compare/v0.2.3...v0.2.4
[0.2.3]: https://github.com/mhenrixon/phlex-reactive/compare/v0.2.2...v0.2.3
[0.2.2]: https://github.com/mhenrixon/phlex-reactive/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/mhenrixon/phlex-reactive/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/mhenrixon/phlex-reactive/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/mhenrixon/phlex-reactive/releases/tag/v0.1.0
