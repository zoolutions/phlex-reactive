# phlex-reactive

[![CI](https://github.com/zoolutions/phlex-reactive/actions/workflows/main.yml/badge.svg)](https://github.com/zoolutions/phlex-reactive/actions/workflows/main.yml)
[![Gem Version](https://img.shields.io/gem/v/phlex-reactive)](https://rubygems.org/gems/phlex-reactive)
[![Docs](https://img.shields.io/badge/docs-phlex--reactive.zoolutions.llc-blue)](https://phlex-reactive.zoolutions.llc)

**Reactive [Phlex](https://www.phlex.fun) components for Rails — Livewire-style
actions and live cross-tab updates, without writing Stimulus controllers or
hand-picking Turbo Stream targets.**

📖 **[Full documentation](https://phlex-reactive.zoolutions.llc)**

```ruby
class Counter < ApplicationComponent
  include Phlex::Reactive::Component   # pulls in Streamable too

  reactive_state :count
  action :increment
  action :decrement

  def initialize(count: 0) = @count = count
  def id = "counter"

  def increment = @count += 1
  def decrement = @count -= 1

  def view_template
    div(**reactive_root) do
      button(**on(:decrement)) { "−" }
      span { @count }
      button(**on(:increment)) { "+" }
    end
  end
end
```

That's the whole counter. **No Stimulus controller. No `.turbo_stream.erb`. No
route. No hand-picked target.** Click `+` and the count updates in place.

---

## Why

Stimulus + Turbo are powerful but tedious. A single interactive widget means a
Stimulus controller, a `data-*` soup, a `.turbo_stream.erb` view, a controller
action, and a hand-picked `dom_id` target — repeated for every feature. The
mental model is "wire everything by hand."

phlex-reactive borrows the **mental model** that makes Livewire and Phoenix
LiveView pleasant — *a component has state and actions; change state and the UI
follows* — and implements it the Rails way:

- **Actions are Ruby methods.** Declare `action :increment`; the client calls it.
- **Re-render is auto-targeted.** A component owns a stable `id`; the response is
  a `<turbo-stream>` that replaces it. You never pick a target.
- **The same unit re-renders for clicks AND broadcasts.** A click and a
  background broadcast both produce "replace the component by its id," so live
  cross-tab updates are the same mechanism as local interactivity.
- **State lives in your database, not the browser.** The DOM carries only a
  *signed identity* (a record's GlobalID), not a snapshot of state — so there's
  no mass-assignment surface and no re-signing protocol.
- **One tiny client runtime.** A single generic Stimulus controller, registered
  once, handles every reactive component. You don't write per-feature JS.

Pair it with [**pgbus**](https://github.com/zoolutions/pgbus) and your live
updates become *transactional* (no broadcast for a rolled-back change) and
*reconnect-safe* (missed messages replay) over Postgres SSE — **no Action Cable,
no Redis.**

---

## Installation

```ruby
# Gemfile
gem "phlex-reactive"
```

```bash
bundle install
```

Then run the installer — it registers the client controller and writes a config
initializer:

```bash
bin/rails generate phlex:reactive:install
```

That's all for **importmap** apps: the engine mounts the action endpoint at
`/reactive/actions` and auto-pins (and preloads) the client runtime, and the
installer adds the eager registration below to your Stimulus entrypoint.

Verify the whole install any time with the doctor — it checks the route, the
Stimulus registration, CSRF, the identity verifier, and every component, printing
`✓/✗/?` with a fix for each failure:

```bash
bin/rails phlex_reactive:doctor
```

<details>
<summary>What the installer wires (or do it by hand)</summary>

```js
// app/javascript/controllers/index.js
import { application } from "controllers/application"
import ReactiveController from "phlex/reactive/reactive_controller"
application.register("reactive", ReactiveController)
```

Register eagerly (not lazily) so a click immediately after load is never missed.
</details>

### Scaffold a component

```bash
# state-backed (record-less)
bin/rails generate phlex:reactive:component Counter increment decrement

# record-backed (signed GlobalID identity)
bin/rails generate phlex:reactive:component Todos::Item toggle rename --record todo
```

Generates the component (and an RSpec spec if your app uses RSpec).

<details>
<summary>esbuild / webpack / bun</summary>

Import and register it from your controllers entrypoint:

```js
import { application } from "./application"
import ReactiveController from "phlex/reactive/reactive_controller"
application.register("reactive", ReactiveController)
```

The gem ships a prebuilt, minified `reactive_controller.min.js` (~22 KB vs the
~106 KB commented source) with a linked sourcemap, and auto-pins it for importmap
apps — so browsers load the small file while devtools still shows the real code.
Point your bundler at the gem path or copy the `.min.js` (+ its `.map`) in. See
[docs/installation.md](https://phlex-reactive.zoolutions.llc/docs/installation).
</details>

**Requirements:** Rails 7.1+, Phlex 2 (`phlex-rails`), Turbo 8+ (for morphing),
and a Phlex `ApplicationComponent` base class. pgbus is optional but recommended
for broadcasting.

### Integration troubleshooting (silent "nothing happens")

Two host-app setups make the first reactive component *silently do nothing* —
components render, but no action ever fires, with no error pointing at the cause.
Run `bin/rails phlex_reactive:doctor` first — it flags both of these (and more)
with the fix inline. The gem also logs a warning for each at boot; here are the
fixes:

**A catch-all route shadows `POST /reactive/actions`.** The engine appends its
route *after* everything in your `config/routes.rb`, so a bottom-of-file
catch-all wins and every reactive POST 404s:

```ruby
# config/routes.rb — a catch-all like this shadows the engine's appended route
match "*path", to: "errors#not_found", via: :all
```

Exempt the reactive path from the catch-all (or set
`Phlex::Reactive.action_path` to an unshadowed path):

```ruby
match "*path", to: "errors#not_found", via: :all,
  constraints: ->(req) { !req.path.start_with?("/reactive/") }
```

At boot the gem warns (`[phlex-reactive] POST /reactive/actions does not resolve
to phlex/reactive/actions …`) when the route is shadowed.

**The `reactive` controller isn't registered (`lazyLoadControllersFrom` apps).**
`lazyLoadControllersFrom("controllers", application)` only registers controllers
under `app/javascript/controllers/`. The gem's controller lives outside that dir,
so `data-controller="reactive"` does nothing until you register it explicitly:

```js
// app/javascript/controllers/index.js (or your Stimulus entrypoint)
import ReactiveController from "phlex/reactive/reactive_controller"
application.register("reactive", ReactiveController)
```

If reactive elements are on the page but the controller never connected, the
runtime logs a console warning (`[phlex-reactive] found N element(s) with
data-controller="reactive" but the reactive controller never connected …`).

### Debugging & tooling

Four read-only introspection surfaces answer "what's reactive, where is it
defined, is it authorized, and what does this page POST?" — plus an installable
Claude Code toolkit. See the [Debugging & tooling
guide](https://phlex-reactive.zoolutions.llc/docs/tooling) for the full workflow.

```bash
bin/rails phlex_reactive:doctor          # validate the whole install (✓/✗/? + a fix each)
bin/rails phlex_reactive:actions         # every component × action: params, file:line, auth
bin/rails "phlex_reactive:find[counter]" # fuzzy-find one; prints each action's method source
bin/rails phlex_reactive:mcp             # a read-only MCP server (needs `gem "mcp"`)
```

In the browser console, map every reactive root + trigger on the page back to its
server `Component#action` names (a standalone module — zero cost until imported):

```js
(await import("phlex/reactive/inspect")).report()
```

Install the debugging skill + MCP config for Claude Code in one command:

```bash
rails g phlex:reactive:claude
```

---

## The mental model in one picture

```
   ┌── click / input ──────────────────────────────────────────┐
   │                                                            ▼
[ button(**on(:increment)) ]          POST /reactive/actions { token, act, params }
   ▲                                                            │
   │                                          verify signed token (no state trusted)
   │                                          rebuild component (record from DB)
   │                                          run the whitelisted action
   │                                          re-render → <turbo-stream replace id>   (default; an action
   │                                          may return reply.<verb> — see "Controlling the action's reply")
   └──────── Turbo applies it in ◀──────────────────────────────┘

   ...and for OTHER tabs/users:
   model change → Component.broadcast_to(stream, replace: model) → pgbus SSE → same morph
```

Client actions and server broadcasts **converge on one re-render unit**: the
component, targeted by its `id`.

---

## Quickstart: a live, cross-tab counter

```ruby
# app/components/counter.rb  — see the top of this README for the full class
render Counter.new(count: 0)
```

Open the page in two tabs, click `+` — done. To make it update across tabs when
the underlying record changes, use a record-backed component (below).

---

## Two kinds of reactive component

### 1. Record-backed (the common case)

State lives in an ActiveRecord row. The signed identity is the record's
GlobalID; the server re-finds it on each action. **Always prefer this.**

```ruby
class Todos::Item < ApplicationComponent
  include Phlex::Reactive::Component

  reactive_record :todo             # identity AND the default #id: dom_id(@todo)
  action :toggle
  action :rename, params: { title: :string }

  def initialize(todo:) = @todo = todo

  def toggle
    authorize! @todo, :update?      # YOU authorize — the token only proves identity
    @todo.toggle!(:done)
  end

  def rename(title:)
    authorize! @todo, :update?
    @todo.update!(title:)
  end

  def view_template
    li(**reactive_root(class: ("done" if @todo.done?))) do
      button(**on(:toggle)) { @todo.done? ? "✓" : "○" }
      span { @todo.title }
    end
  end
end
```

> **One include, default `#id` (issue #81).** `include Phlex::Reactive::Component`
> pulls in `Streamable` automatically (the explicit two-include form still works
> and is a harmless no-op). A record-backed component also gets `#id` for free —
> `dom_id(record)`, exactly the id nearly every one wrote by hand — so `def id`
> is only needed to override it, and an explicit `def id` always wins.
> **Caveat:** two *different* component classes rendering the *same* record on
> one page both default to the same `dom_id` and collide — give one an explicit
> prefixed id: `def id = dom_id(@todo, "rich")`. State-backed components still
> must define `#id` (they're frequently multi-instance, so a class-name default
> would silently collide; the loud `NotImplementedError` stays).

### 2. State-backed (signed instance vars)

Sign small, JSON-serializable instance vars into the token. Use it **alone** for
a record-less widget (a counter, a wizard step), or **alongside `reactive_record`**
to carry transient UI state — which field, what mode — next to the row. Both the
record's GlobalID and the state are signed into one token and rebuilt on each
action. Keep state small and JSON-serializable.

```ruby
reactive_state :count, :step       # signed; rebuilt on each action
```

The [inline edit example](https://phlex-reactive.zoolutions.llc/docs/example-inline-edit) combines both: a
`reactive_record :record` plus `reactive_state :attribute, :editing`.

---

## Concrete examples

| Example | What it shows |
|---|---|
| [Counter](https://phlex-reactive.zoolutions.llc/docs/example-counter) | State-backed, the smallest reactive component |
| [Payment split](https://phlex-reactive.zoolutions.llc/docs/example-payment-split) | Nested bracketed params, auto-collected siblings, and a live `reactive_compute` + `reactive_text` preview (#64–#67, #104) |
| [Cross-tab chat](https://phlex-reactive.zoolutions.llc/docs/example-chat) | Record-backed action **+ pgbus broadcast** → live sync across tabs/browsers |
| [Live todo list](https://phlex-reactive.zoolutions.llc/docs/example-todo-list) | Per-row components, add/toggle/rename/archive, optimistic toggle + delete, Enter-to-add, broadcast on change |
| [Inline edit + dirty tracking](https://phlex-reactive.zoolutions.llc/docs/example-inline-edit) | Show ↔ edit toggle plus an "Unsaved" badge + leave-guard, with zero shipped state |
| [Notifications / badges](https://phlex-reactive.zoolutions.llc/docs/example-notifications) | Pure broadcast — a background event pushes a re-render, plus a `broadcast_to(js:)` cross-tab pulse |
| [Reactive collections](https://phlex-reactive.zoolutions.llc/docs/example-collections) | Add/remove rows + a running count + an empty state, declared **once** with `reactive_collection`, optimistic dismiss |
| [Loading states](https://phlex-reactive.zoolutions.llc/docs/example-loading-states) | `disable_with:` + `busy_on` + `aria-busy`, with a latency toggle to make the pending window visible |
| [Client-only ops](https://phlex-reactive.zoolutions.llc/docs/example-client-ops) | `on_client` tabs / outside-close menu / accessible drawer — zero fetches, zero custom JS |
| [Failure surface](https://phlex-reactive.zoolutions.llc/docs/example-failure) | `error_flash` + `data-reactive-error` + `dismiss_after:` — what you get for free when an action fails |
| [Team inbox (flagship)](https://phlex-reactive.zoolutions.llc/docs/example-team-inbox) | The whole toolkit in one UI: collection rows, optimistic archive that **reverts on failure**, cross-tab broadcast, an `on_client` kebab, error flashes |
| [Project board (flagship)](https://phlex-reactive.zoolutions.llc/docs/example-project-board) | The kanban: cards move across lanes with **enter/exit effects** (per-visitor style picker incl. `random`), live count badges in every tab via `broadcast_to(js:)`, nested reactive rows with inline rename, confirm-gated archive |

Every page renders its **real** reactive component inline (source read straight
off the file), so the demo and the code can never drift. The
[Team inbox](https://phlex-reactive.zoolutions.llc/docs/example-team-inbox) and the
[Project board](https://phlex-reactive.zoolutions.llc/docs/example-project-board) are the
flagships — every feature composed into believable UIs.

---

## API reference

### `Phlex::Reactive::Streamable`

| Method | Use |
|---|---|
| `#id` | Stable DOM id == Turbo Stream target. Must match the root element's `id`. Record-backed components default to `dom_id(record)` (issue #81); everything else implements it (`def id`). An explicit `def id` always wins. |
| `.replace(model = nil, morph: false, **opts)` | `<turbo-stream action=replace target=id>` of a freshly built component; `morph: true` adds `method="morph"` |
| `.update(model = nil, morph: false, **opts)` | `<turbo-stream action=update target=id>` (inner-HTML update); `morph: true` adds `method="morph"` so Turbo morphs the inner HTML in place (issue #113) |
| `.append(target:)` / `.prepend(target:)` / `.remove` | The other Turbo Stream actions |
| `.broadcast_to(*streamables, replace: model, morph: false)` | Broadcast a replace over the stream transport (pgbus SSE / Action Cable); `morph: true` morphs in place |
| `.broadcast_to(*streamables, update: model, morph: false)` | Broadcast an inner-HTML update; `morph: true` morphs in place, so a peer editing the component keeps its focus/caret (issue #113) |
| `.broadcast_to(*streamables, append: model, target:)` / `prepend:` / `remove:` | The other broadcast verbs — the verb is a kwarg (exactly one of `replace:`/`update:`/`append:`/`prepend:`/`remove:`/`js:`) |
| `.broadcast_to(each: stream_keys, replace: model, morph: false, exclude:, visible_to:)` | **Render once, fan out** the *same* payload to K different stream keys — a per-tenant loop. Pass `each:` instead of `*streamables`. K renders + K HMACs collapse to 1 + K cheap channel calls (~9.5× at K=10). Each key is a `[record, :symbol]` pair (or a bare string). Transport opts + `morph:` forward per key. Per-viewer `visible_to:` content stays render-per-call. See [Broadcasting](https://phlex-reactive.zoolutions.llc/docs/broadcasting). |
| `#to_stream_replace(morph: false)` / `#to_stream_remove` | Stream the *already-built* instance (used internally after an action / by `reply`); `morph: true` morphs in place |
| `#to_stream_update(morph: false)` | Inner-HTML update of the *already-built* instance; `morph: true` morphs in place (issue #113) |

Use in controllers: `render turbo_stream: Counter.replace(counter)`.

### `Phlex::Reactive::Component`

| Macro / helper | Use |
|---|---|
| `reactive_record :name` | Record-backed identity (GlobalID). State = the DB. Also defaults `#id` to `dom_id(record)`. |
| `reactive_state :a, :b` | Signed instance-var identity. Standalone, or combined with `reactive_record` to sign transient UI state alongside the row. |
| `action :name, params: { x: :integer }` | Declare a client-invokable action + its param schema. **Default-deny.** |
| `mark_authorized!` | Inside an action: satisfy the `verify_authorized` guard after a bespoke check the interceptor can't see (a hand-rolled policy). Call it only after your check passes. |
| `skip_verify_authorized [ :a, :b ]` | Opt a component (bare) or specific actions out of the default-ON `verify_authorized` guard — for a genuinely public component (a counter, a client-only filter). |
| `reactive_root(**overrides)` | Spread onto the root element: emits the component `id` **and** `reactive_attrs` together, so the controller root always carries `#id`. Preferred over `id:` + `reactive_attrs`. `**overrides` (`class:`/`data:`) deep-merge. `compute: :name` binds a client-side compute **at the root** — descriptors plus the `input->reactive#recompute` delegation, so no field needs its own wiring; `nil` collapses to no binding. See [Client-side computes](#client-side-computes-reactive_compute--reactive_text). |
| `reactive_attrs` | Marks an element reactive + carries the signed token (no `id`). Spread alongside `id:` on the **same** element: `div(id:, **reactive_attrs)`. Prefer `reactive_root`, which can't split them. |
| `on(:action, event: "click", **params)` | Spread onto a trigger element. Adds `type=button` for clicks. |
| `on(:action, event: "input", debounce: 300)` | Coalesce rapid events into one round trip after a quiet period (live-as-you-type). |
| `on(:action, event: "keydown.enter")` | Fire only on a specific key — Enter-to-submit / Escape-to-cancel — via Stimulus's native keyboard filter (`event:` passes straight through). See [Keyboard triggers](#keyboard-triggers-enter-to-submit--escape-to-cancel). |
| `on(:action, confirm: "Sure?")` | Gate a destructive trigger behind a confirmation. Defaults to `window.confirm`; override the dialog with [`setConfirmResolver`](#custom-confirmation-dialogs-setconfirmresolver). |
| `on(:search, listnav: "[role=option]")` | Add combobox keyboard navigation — Arrow keys move a client-side highlight, Enter picks (clicks the option's own trigger), Escape clears. See [Combobox keyboard navigation](#combobox-keyboard-navigation-listnav). |
| `on(:close_menu, outside: true)` | Fire only for events **outside** this component's root (close-a-dropdown-on-outside-click). Window-bound; never `preventDefault`s, so links elsewhere keep navigating. |
| `on(:track, event: "scroll", window: true, throttle: 250)` | `window:` binds the trigger to the window (page-level scroll/resize); `throttle:` rate-limits leading-edge — first event fires, the rest drop until the window elapses. Mutually exclusive with `debounce:`. |
| `on(:toggle, optimistic: { checked: :keep })` | Apply a reversible **visual hint** the instant the trigger fires (before the round trip); revert it if the action fails. Cosmetic only. See [Optimistic hints](#optimistic-visual-hints-optimistic). |
| `on(:save, disable_with: "Saving…")` | Disable the trigger + swap its text while the action is pending (a disabled button also swallows a rapid double-click). Shorthand for `loading: { disable: true, text: "Saving…" }`. See [Loading states](#declarative-loading-states-loading--disable_with). |
| `on(:save, loading: { disable: true, class: "opacity-50", text: "…" })` | Full loading form: `disable:`, a loading `class:` (on the trigger or a `to:` target), a `text:` swap. Reverts on settle. |
| `busy_on(:save)` | Mark any element so it carries `data-reactive-busy` **only while `save` is in flight** — a spinner styled with pure CSS, zero Ruby. See [Loading states](#declarative-loading-states-loading--disable_with). |
| `on(:action, once: true)` | Fire at most once, then unbind (Stimulus's native `:once`). |
| `on_client(:click, js.toggle("#menu"))` | **Client-only** trigger: applies declared DOM ops with ZERO round trip — no token, no POST, ever. Takes the same `window:`/`once:`/`outside:` modifiers. See [Client-only ops](#client-only-ops-on_client--js--zero-round-trips). |
| `js` | The immutable op builder behind `on_client`: `show`/`hide`/`toggle` (the `hidden` attribute, with an optional `transition:`), `add_class`/`remove_class`/`toggle_class`, `set_attr`/`remove_attr`/`toggle_attr` (allowlisted names), `focus`/`focus_first`, `text` (set `textContent` — XSS-safe), `dispatch`, `submit` (requestSubmit the target's own form), `paste_into` (read the clipboard into a field, gesture-gated), and `persist_state`/`persist_clear` (the `reactive_persist` draft) — chainable. |
| `reactive_field(:param, **attrs)` | The attribute hash that binds a control to an action param (no magic `name:`) — spread onto any control: `input(**reactive_field(:value, value: @record.name))`, `select(**reactive_field(:status)) { … }`. |
| `reactive_text(:name, initial)` | Mirror a compute output (or a declared input) into a **text node** — a live preview heading, a character counter, `"Hello, {name}"` — via `textContent` (XSS-safe). The text sibling of `reactive_field`; carries no `name`, so it's never POSTed. See [Client-side computes](#client-side-computes-reactive_compute--reactive_text). |
| `reactive_show(if:/if_any:/unless:)` | **Value-conditional visibility** (the `x-show`/`data-show` case): spread onto the element to show/hide — it toggles `hidden` from the fields' **current values**, client-only, zero round trip. One conditions language: a **Hash is an AND**, an **Array is membership**, a **Range is a threshold**, `if_any:` is OR-of-AND, `unless:` negates. `reactive_values` computes first paint; `disable:` disables a hidden section's controls. See [Value-conditional visibility](#value-conditional-visibility-reactive_show). |
| `reactive_show_targets(:field, "#id" => value)` | **Cross-root visibility**: the component that owns the field declares which **outside**, id-allowlisted elements it governs (a nav tab, a panel in another pane) — the visibility parallel of `mirror:`. Spread on the **root** via `mix(reactive_root, …)`, **once per root** — several fields go in one call via the hash form. The value uses the same `where`-style vocabulary (`"advanced"`, `%w[a b]`, `10..`); a `"#id"` **key** takes a full conditions Hash for a **multi-field** predicate (`"#warn" => { if: { type: "trade", price: ..0 } }`). Id selectors only (raise at render + client warn-skip); toggles `hidden` only. See [Value-conditional visibility](#value-conditional-visibility-reactive_show). |
| `reactive_persist(key:, ttl: 7.days)` | **Client-only drafts**: spread on the **root** (once) and the generic controller keeps a `localStorage` draft of every **owned** control — debounced write on `input`, immediate on `change`, flushed on disconnect, restored into **blank** controls on the next connect (`restore: :always` lets the draft win), cleared by a successful Turbo submit / `ttl` / `js.persist_clear`. Never hidden/file/password; `reactive_persist_skip` opts a control out; `fields:` narrows. See [Client-only drafts](#client-only-drafts-reactive_persist). |
| `js.persist_state(step: 2)` / `js.persist_clear` | The draft ops (actor-only): merge a flat state bag into the draft (restored as `data-reactive-persist-state` + the `reactive:persist-restored` event) / forget the draft. |
| `reactive_filter(:field, option: nil, group: nil, empty: nil)` | **Client-side option filtering** for a preloaded combobox: spread onto the root and name the **field** that drives it — `reactive_filter(:q)` compiles `:q` to `[name="q"]` (scope-aware) and typing shows/hides the options by their `data-reactive-filter-text` haystack, **zero round trips**. `option:` defaults to `[role=option]`; optional `group:` collapses an all-hidden group header; `empty:` reveals a no-matches node. `input:` is the escape hatch — a raw CSS selector for a **name-less** driving input (`input: "#tags_query"`), the form-builder case. See [Client-side option filtering](#client-side-option-filtering-reactive_filter). |
| `reactive_listnav("[role=option]")` | The **standalone** combobox keyboard wiring (Arrow/Enter/Escape) for an input that fires **no action** — the preload-and-filter case. Same behavior as `on(…, listnav:)`, minus the POST. |
| `reactive_tags(:tags)` | **Tag-chip input** (the combobox/tags widget): spread onto the root and name the hidden field that stores the **comma-joined** value — the client maintains that field + the chip list entirely client-side (form state, zero round trips), rebuilding chips from your server-owned `<template>`. Composes with `reactive_filter` (type to narrow) and `reactive_listnav` (Enter picks the highlighted option). `name:` is the escape hatch — a **verbatim** wire name (`name: "user[tags]"`, never re-scoped), the form-builder case. See [Tag-chip input](#tag-chip-input-reactive_tags). |
| `reactive_tags_add` / `reactive_tags_option(tag)` / `reactive_tags_remove(tag)` | The tags triggers, all **client-only**: `reactive_tags_add` on the query input adds the typed text on Enter (mix it **after** `reactive_listnav`; Enter never submits the enclosing form); `reactive_tags_option` makes a preloaded suggestion add its declared tag on click; `reactive_tags_remove` is a chip's remove button (no arg inside the template — the client fills the tag per chip). |
| `reactive_compute :name, inputs: { title: :string, qty: :number }, outputs:` | **Typed** inputs: a `:string` reaches the JS reducer raw, a `:number` is coerced through `Number`. The array form (`inputs: %i[a b]`) stays all-numeric; the **permit-style** form (`inputs: [:qty, title: :string]`) mixes both — bare symbols default `:number`, a trailing hash types the exceptions. `outputs:` is the field allowlist; a reducer-result key also paints any owned `reactive_text` node by presence and any `mirror:` id, so an `outputs:` entry that exists only to reach a text node is redundant (harmless — a widening). |
| `reactive_compute :name, ..., mirror: { sum: "#summary-sum" }` | **Cross-root text mirrors**: paint a compute value into declared, id-allowlisted nodes **outside** the reactive root (a recap in another tab pane) via `textContent` — no bespoke listener. See [Cross-root mirrors](#cross-root-mirrors-mirror--painting-a-recap-outside-the-root). |
| `reactive_dirty` / `reactive_dirty warn_unsaved: true` / `reactive_dirty only: %i[...]` | **Dirty tracking**, declared once at the class level, against the DOM's own `defaultValue`/`defaultChecked`/`defaultSelected` — no client state. Marks changed fields + the root `data-reactive-dirty`; `warn_unsaved:` arms a `beforeunload`/`turbo:before-visit` guard; `only:` scopes tracking to named fields. Style with `[data-reactive-dirty]`. See [Dirty-field tracking](#dirty-field-tracking-reactive_dirty). |
| `nested_update!(:assoc, attrs)` | Map a nested param onto `<assoc>_attributes` with id preservation; update the record. |
| `reactive_nested_list(:assoc, as: :attributes \| :json)` / `reactive_nested_template(:assoc)` / `reactive_nested_row` | **Draft nested-attribute rows** (the "new parent + child rows" form): the container rows land in, the `<template>` holding ONE row's markup, and the row wrapper marker — all **client-only** form state, keyed by association (several collections per root). `as: :json` (default `:attributes`) serializes the rows into ONE hidden JSON field instead of posting `accepts_nested_attributes_for` names — for an app whose controller `JSON.parse`s a serialized param; `name:` names that hidden field **verbatim** (`name: "order[todos]"`, never re-scoped — the form-builder escape hatch, JSON mode only). See [Draft rows for a new parent](#draft-rows-for-a-new-parent-reactive_nested_). |
| `reactive_nested_add(:assoc, from:, clear:)` / `reactive_nested_remove(confirm:)` | The row triggers, client-only (zero round trips): add clones the template and renumbers its placeholder index; remove deletes a draft row from the DOM, or `_destroy`-marks + hides a persisted row (a hidden `[_destroy]` input present). **Fill-then-add**: `from: { row_field => "#source-selector" }` seeds the new row from add controls that live OUTSIDE it (a preset select, a typeahead), and `clear: true` resets them — composes with `as: :attributes` AND `as: :json`. **Confirm on remove**: `reactive_nested_remove(confirm: "Really delete this row?")` gates the remove behind the same overridable `confirmResolver` as `on`/`on_client` (a per-row string, or the conditional `{ when:, message: }` Hash). See [Draft rows for a new parent](#draft-rows-for-a-new-parent-reactive_nested_). |
| `nested_field_name(:assoc, :field, index: nil)` | The Rails `accepts_nested_attributes_for` wire name for one row field — `order[line_items_attributes][NEW_ROW][quantity]` (the template placeholder) by default, a real index when given. Scope-aware under `reactive_scope`; `scope:` overrides it **per call** (`scope: "order"`, verbatim — the form-builder escape hatch). |
| `reactive_collection :name, item:, container:, count:, empty:, size:` | Declare an add/remove-row list once; actions call `reply.append`/`prepend`/`remove`. See [Reactive collections](#reactive-collections-addremove-rows--count--empty-state). |
| `reply.replace` / `.morph` / `.update` / `.remove` / `.redirect(url)` / `.with(*)` / `.js(ops)` | Return from an action to control the reply (flash, remove, redirect, multi-stream, server-pushed client ops). See [Controlling the action's reply](#reply--controlling-the-actions-reply). |
| `reply.append(name, model)` / `.prepend(...)` / `.remove(name, model)` | Add/remove a row in a declared `reactive_collection` (row + count + empty-state in one reply). |
| `reply.pending(records, in:, job:) { … }` + `include Phlex::Reactive::Settles` / `reactive_settle` | For an action that **enqueues** work: mark targets pending, let your job settle them (row + count + empty-state) when it finishes. See [Async actions](#async-actions-replypending--reactive_settle). |
| `Container.broadcast_collection_to(*keys, container:, in:, append:/prepend:/remove:)` | The broadcast-side `reply.append`/`reply.remove`: the row **plus** the count companion **plus** the empty-state toggle, to peers. |

Param types: `:string` (default), `:integer`, `:float`, `:boolean`, `:file`,
`:date`, `:datetime`, `:decimal`. Anything not in the schema is dropped before
reaching your method. `:date`/`:datetime` parse ISO8601 (a value that won't
parse is dropped — the keyword default applies); `:decimal` parses through
`BigDecimal` (dropped on a non-numeric value). The schema is **compiled once at
declaration**: a typo'd type symbol (`params: { count: :interger }`) raises
`Phlex::Reactive::UnknownParamType` at class load, not silently coercing to a
string at click time.

**Custom param types (`Phlex::Reactive.param_type`).** Register your own type in
an initializer — the block receives the raw client value and returns the coerced
value, or `Phlex::Reactive::ParamSchema::DROP` to reject it (the keyword default
then applies, keeping the drop-don't-fabricate contract):

```ruby
# config/initializers/phlex_reactive.rb
Phlex::Reactive.param_type(:money) do |value|
  /\A\d+(\.\d{1,2})?\z/.match?(value.to_s) ? BigDecimal(value) : Phlex::Reactive::ParamSchema::DROP
end

# then, in any component:
action :charge, params: { amount: :money }
def charge(amount:) = @invoice.charge!(amount) # amount is a BigDecimal or unset
```

Register during boot only: the registry is **frozen after initialization**, so a
runtime `param_type` call raises. A schema referencing a registered type is
validated at declaration like any built-in.

**Named param schemas (`Phlex::Reactive.param_schema`).** Register a reusable
schema once so sibling components stop duplicating a verbatim params Hash that
drifts — follows the same boot-only contract as `param_type`:

```ruby
# config/initializers/phlex_reactive.rb
Phlex::Reactive.param_schema :todo, title: :string, done: :boolean

# then, in any component:
action :save, params: :todo

# or compose it into a bigger schema:
action :bulk, params: { **Phlex::Reactive.param_schema(:todo), note: :string }
```

Reading an unregistered name raises, listing the ones that are registered.

**File uploads (`:file`).** Declare `:file` (or `[:file]` for multiple) to accept
an uploaded file in a reactive action — attach a document/receipt/image to the
record without dropping out to a bespoke controller. When the reactive root holds
a populated `<input type="file">`, the client sends the action as multipart
`FormData` (instead of JSON) — `token` + `act` as fields, scalar params as fields,
any nested/array params bracket-expanded into `params[key][sub]` /
`params[key][index]` fields (the same Rails-form shape, so a JSON body and a
multipart body coerce identically — #39), and the file(s) appended. A
Rails-bracketed field **name** (`blog_post[summary]`, `blog_post[image]`)
expands the same way — `params[blog_post][summary]`, never the unparseable
`params[blog_post[summary]]` (#231). The endpoint
coerces `:file` to the `ActionDispatch::Http::UploadedFile`, passed through
untouched. A non-file value sent to a `:file` param is dropped (the keyword
default applies — never a fabricated file). Token threading and the
re-render/morph are identical; only the request encoding changes when a file is
present.

```ruby
reactive_record :document
action :upload, params: { file: :file, caption: :string } # single (has_one_attached)
action :upload_pages, params: { pages: [:file] }           # multiple (has_many_attached)

def upload(file: nil, caption: nil)
  @document.file.attach(file) if file
  @document.update!(title: caption) if caption.present?
end

def view_template
  form(**on(:upload, event: "submit")) do
    input(type: "file", name: "file")
    input(name: "caption")
    button(type: "submit") { "Upload" }
  end
end
```

> **One multipart caveat:** `FormData` can't carry an *empty* array or hash, so on
> the multipart (file-present) path an empty `[]`/`{}` param is **omitted** and the
> action's keyword default applies — it does **not** arrive as an explicit empty
> collection the way it does over JSON. If you rely on sending `tags: []` to clear
> a collection, send that action *without* a file (the JSON path). A non-empty
> nested/array param rides along fine next to a file.

**Array & nested params.** Wrap a type in an array for an array param, or a hash
schema in an array for Rails-style nested attributes — so one reactive action can
mirror a normal nested-attributes update instead of forcing a per-row component:

```ruby
action :save, params: {
  date: :string,
  bank_account_ids: [:integer],                         # array of scalar
  invoice_items_attributes: [                            # array of hash
    { id: :integer, quantity: :float, price: :float, _destroy: :boolean }
  ]
}

def save(date:, bank_account_ids:, invoice_items_attributes:)
  @invoice.update!(date:, bank_account_ids:, invoice_items_attributes:)
end
```

Nested coercion recurses per field, drops undeclared nested keys, and accepts an
array as either a JSON array or a Rails index hash (`{ "0" => …, "1" => … }`).

**Model-scoped form fields just work.** A standard Rails `Form(model: @invoice)`
names its inputs `invoice[date]`, `invoice[status]`, … and the client posts those
names verbatim. A nested schema matches them with zero field renaming — the
endpoint expands bracket notation before coercion, so `invoice[date]` nests under
`invoice` and `invoice_items_attributes[0][qty]` becomes the index-hash form
above:

```ruby
action :save, params: {invoice: {date: :string, status: :string}}
# client posts { "invoice[date]": "…", "invoice[status]": "…" }  → save(invoice: { date:, status: })
```

> **A flat schema silently drops bracketed names (issue #67).** The schema must
> mirror the field *names*, not the conceptual params. Because the endpoint
> expands `invoice[date]` to `{ "invoice" => { "date" => … } }` **before**
> matching the schema, a flat `params: { date: :string }` matches nothing — the
> top-level key is now `invoice`, not `date`. There is no error: the action just
> receives its keyword defaults (`date` never set). If your inputs are named
> `invoice[…]` (any `Form(model:)`-style form), nest the schema under `invoice:`
> to match. When in doubt, read a field's real `name` attribute and shape the
> schema to it.

**Nested reactive components compose.** A reactive component rendered inside
another is its own root — field collection stops at nested
`data-controller="reactive"` roots, so an outer action collects only *its own*
named inputs, never a nested component's. An invoice editor's `save` sees its
flat fields; each line-item row's `quantity`/`price` belong to that row's own
action. No name-disjointness workarounds required.

**Debounced triggers (live-as-you-type).** Pass `debounce:` (milliseconds) to
coalesce rapid events — typically keystrokes on an `"input"` trigger — into a
single action round trip fired after the quiet period, instead of one POST per
keystroke. A blur flushes a pending dispatch so the last edit is never dropped.
Omit `debounce:` for the immediate-dispatch default.

```ruby
# Recompute a total live as the user types, without hammering the endpoint.
input(**mix(on(:update, event: "input", debounce: 300), name: "quantity", value: @item.quantity))
```

**Event modifiers — `outside:`, `window:`, `once:`, `throttle:`.** Four more
`on(...)` options cover the page-level trigger patterns that otherwise need a
hand-written Stimulus controller:

- `outside: true` fires the action only for events whose target is **outside**
  this component's root — the close-a-dropdown-on-outside-click pattern. An
  event inside the root is a complete client-side no-op. Implies `window:`.
- `window: true` binds the trigger to the window (Stimulus's native `@window`)
  for page-level events like `scroll`/`resize`. Window-bound triggers are
  **never `preventDefault`-ed** — a mounted dropdown must not kill link clicks
  elsewhere on the page — and skip the forced `type="button"`.
- `once: true` fires at most once, then unbinds (Stimulus's `:once`).
- `throttle: 250` rate-limits **leading-edge**: the first event fires
  immediately, further events are dropped until the window elapses. The mirror
  of `debounce:` (trailing-edge) — passing both raises `ArgumentError`.

```ruby
# A dropdown that closes itself on any click outside — no Stimulus controller.
div(**mix(reactive_root, on(:close_menu, outside: true))) do
  button(**on(:toggle_menu)) { "Menu" }
  ul { menu_items } if @open
end

# Throttled page-scroll tracking.
div(**mix(reactive_root, on(:track, event: "scroll", window: true, throttle: 500)))
```

These four (like `debounce:`/`confirm:`/`listnav:`) are **reserved keyword
names** on `on(...)` — no longer usable as free action params.

### Optimistic visual hints (`optimistic:`)

Every reactive action waits a full round trip for its visual change — and it's
worse than neutral for a checkbox: the client `preventDefault`s the trigger, so
an `on(:toggle)` checkbox never even **flips** until the morph arrives.
`optimistic:` gives Livewire's "flip it client-side, let the morph correct" (and
React's `useOptimistic`): a small, **always-reversible**, cosmetic vocabulary
applied the instant the trigger fires and **reverted** if the round trip fails.

Hints are visual **only** — never data, never a computed value (that would be
client state the DOM can't be trusted to hold). Supported ops in the hint hash:

- `toggle_class:` / `add_class:` / `remove_class:` — a class string or array,
  applied to the **trigger** by default, or to a `to:` selector scoped to the
  root (`to: :root` targets the root element itself).
- `checked: :keep` — for a **click-bound** checkbox/radio, the client skips its
  unconditional `preventDefault` so the **native flip happens now** (a bare
  toggle click has no navigation default to lose). `on(...)` also skips the
  forced `type="button"` it normally adds to click triggers — that would destroy
  the very checkbox being toggled — so you supply the real `type="checkbox"` /
  `type="radio"`. On a `change`-bound control the flip is already native
  (`change` isn't cancelable) — `:keep` then only contributes the failure revert.
- `hide: true` — hides the target immediately.

```ruby
# A checkbox that flips instantly; the label paints in the same gesture. The
# morph reconciles from server truth; a failure snaps both back.
input(type: "checkbox", checked: @todo.done,
  **mix(on(:toggle, event: "change", optimistic: { checked: :keep, toggle_class: "is-done", to: ".status" }),
    name: "done"))

# Instant delete: hide the row NOW, remove it on the reply.
button(**on(:destroy, confirm: "Delete?", optimistic: { hide: true, to: :root })) { "Delete" }
```

**The success/failure contract (load-bearing):**

- **On failure** — any branch (`redirected` / `http` / `content-type` /
  `network`, plus a client-side `apply` throw) — the client replays the exact
  **inverse** ops, guarded by `isConnected` (a detached row is skipped, it's
  gone anyway). The hint stored on the queued request, so the serialized
  per-controller queue reverts the **right** request's hint.
- **On success there is NO cleanup.** A reply that re-renders the root
  **overwrites** the hint with server truth. A reply that does **not** re-render
  the root (`reply.remove`, streams-only) **leaves the hint standing** — that's
  the `hide: true` + `reply.remove` instant-delete recipe working as intended:
  the row hides, then removes, and never flashes back.

`optimistic:` (like `debounce:`/`confirm:`/`throttle:`) is a **reserved keyword
name** on `on(...)`. An unknown hint op, a `checked:` value other than `:keep`,
or a non-hash raises at render — a dead hint fails loudly, never silently.

### Declarative loading states (`loading:` / `disable_with:`)

Between the click and the morph, the user needs to see that something is
happening — and a mutating button needs to stop a rapid double-click from firing
twice. `loading:` / `disable_with:` are Livewire's `wire:loading` +
`phx-disable-with` and LiveView's `phx-click-loading`, without a Stimulus
controller. Both are **reserved keyword names** on `on(...)`.

The moment a request is **enqueued** — covering the queue wait, not just the
fetch — the trigger and root get the always-on busy vocabulary, and (if declared)
the loading hint applies; everything reverts when the round trip settles
(success **or** failure), guarded so a re-rendered trigger is never clobbered.

**`disable_with:` — the common case.** Disable the trigger and swap its text
while pending. A disabled button fires no further clicks, so a rapid double-click
enqueues exactly **one** POST (the queue only serializes tokens — it does not
dedupe; the disable is what dedupes):

```ruby
button(**on(:save, disable_with: "Saving…")) { "Save" }
```

**`loading:` — the full form.** A hash of:

- `disable: true` — disable the trigger while pending.
- `class: "…"` / `[ … ]` — a loading class on the **trigger**, or on a `to:`
  selector scoped to the root (`to: :root` targets the root element itself).
- `text: "Saving…"` — swap the trigger's `textContent` while pending.

```ruby
button(**on(:destroy, confirm: "Sure?", loading: { disable: true, class: "opacity-50 pointer-events-none" })) { "Delete" }
```

`disable_with: "Saving…"` is the shorthand for `{ disable: true, text: "Saving…" }`
and, if you pass both, merges over an explicit `loading:` (its `text`/`disable`
win). An unknown loading key or a non-hash `loading:` raises at render.

**The `aria-busy` + `data-reactive-busy` contract (always on — zero Ruby).**
Independent of any `loading:` hint, **every** reactive round trip marks the DOM
for the whole enqueue→settle window, so you can style spinners and dimming with
pure CSS:

- the **trigger** and the **root** carry `data-reactive-busy="<action>"` (a
  **space-separated set** on the root, so two concurrent actions never clobber);
- the **root** carries `aria-busy="true"` (driven by a pending counter — it
  clears only when the last in-flight request settles, so overlapping actions
  don't clear it early);
- `busy_on(:action)` marks any element inside the root so **it** gets
  `data-reactive-busy` toggled **only while that action is in flight** — a scoped
  spinner:

```ruby
button(**on(:save, disable_with: "Saving…")) { "Save" }
span(**busy_on(:save), class: "spinner")
```

phlex-reactive ships **no CSS** for these — you own the styling. A minimal
example (not shipped — copy into your app's stylesheet):

```css
/* Reveal a busy_on / aria-busy spinner only while its action is in flight. */
.spinner { display: none; }
[data-reactive-busy] .spinner,
[data-reactive-busy].spinner { display: inline-block; }

/* Dim the whole component during any round trip. */
[aria-busy="true"] { opacity: 0.6; transition: opacity 120ms ease; }
```

The disable + text swap apply **only at enqueue**, never during a `debounce:`
quiet period — so a debounced `input` trigger (whose element *is* the text field)
is not disabled mid-typing. On settle the text is restored only if it still
matches what was swapped in; a morph that rendered a **new** server label is left
alone.

### Dirty-field tracking (`reactive_dirty`)

Show "unsaved changes", enable **Save** only when something changed, or warn
before navigating away — Livewire's `wire:dirty` — **without shipping any client
state**. The trick: the browser already holds the last server-rendered value with
zero extra bytes. `input.defaultValue` / `defaultChecked` / `option.defaultSelected`
**are** the attributes from the last render. So **dirty = current ≠ default**, and
phlex-reactive reads that baseline straight from the DOM — nothing to snapshot,
nothing to sign.

`reactive_dirty` is declared **once, at the class level**, alongside your other
macros (`reactive_record`/`reactive_state`/`action`) — not as a `reactive_root` or
`reactive_field` keyword:

```ruby
class TodoForm < ApplicationComponent
  include Phlex::Reactive::Component

  reactive_record :todo
  reactive_dirty warn_unsaved: true
  action :save, params: { title: :string }

  def view_template
    div(**reactive_root) do
      input(**reactive_field(:title, value: @todo.title))
      span(class: "unsaved-badge") { "Unsaved" }   # shown via [data-reactive-dirty] CSS
      button(**on(:save, disable_with: "Saving…")) { "Save" }
    end
  end
end
```

- **`reactive_dirty`** (no args) wires every input under the root to a full
  re-scan on change. **`reactive_dirty only: %i[title]`** scopes tracking to the
  named fields only — each carries its own descriptor instead of the root
  delegating for the whole subtree (use it when only some fields should count).
- On each change the client re-scans **every field the root owns** in one pass and
  marks:
  - each changed field with **`data-reactive-dirty="true"`**, and
  - the root with **`data-reactive-dirty="<count>"`** (the attribute is **absent
    at zero** — so `[data-reactive-dirty]` matches iff the form is dirty).
- The re-scan is a **full pass**, not a per-field toggle — required for radio
  groups: deselecting a radio fires no event on the *deselected* one, so only
  re-scanning everything keeps its flag honest.

**The CSS vocabulary (you own the styling — phlex-reactive ships none):**

```css
/* Reveal an "unsaved" badge only while the form has changes. */
.unsaved-badge { display: none; }
[data-reactive-dirty] .unsaved-badge { display: inline; }

/* Outline just the fields that changed. */
[data-reactive-dirty] { outline: 2px solid gold; }

/* Enable Save only when dirty (pair with a :disabled default). */
[data-reactive-dirty] button[data-testid="save"] { pointer-events: auto; opacity: 1; }
```

**Baselines reset on the server's re-render.** A plain replace re-connects the
controller (re-scan on `connect`); an in-place **morph** keeps the element
connected and fires no Stimulus lifecycle, so the client also re-scans on
`turbo:morph-element` after the morph writes fresh `default*` attributes. So a
`reply.morph` save renders the field with the new value as its **new default**,
and the badge clears with no reload. (Turbo 8 morph preserves a focused field's
in-progress value while writing the fresh defaults — the post-morph re-scan is
what keeps the root count honest in that state.)

**`reactive_dirty warn_unsaved: true`** arms a navigate-away guard gated on the
**live** dirty count: `beforeunload` (a real browser unload) and
`turbo:before-visit` (a Turbo in-app navigation). A clean form never blocks.
**Caveats:** browsers show their own generic `beforeunload` copy (your message
string is legacy and ignored), and `turbo:before-visit` **does not fire on
restoration visits** (Back/Forward) — a documented Turbo gap, not a
phlex-reactive one.

**Out of scope (v1):** rich-text / `contenteditable` editors have no `default*`
baseline and are **not** tracked. Combining `reactive_field` with your own
`data:`/`on(...)` still needs `mix(...)` (a bare merge clobbers the `data-action`
the descriptor rides on — the same rule as everywhere else).

### Client-only ops (`on_client` + `js`) — zero round trips

Not every interaction needs the server. A tab switch, a dropdown, an accordion
— purely visual state — used to mean either a wasteful signed round trip or the
very Stimulus controller this gem exists to eliminate. `on_client` binds a DOM
event to a chain of **declared DOM operations** that the one generic controller
applies locally: **no token, no params, no POST, ever.**

```ruby
def view_template
  div(**mix(reactive_root, on_client(:click, js.hide("#menu"), outside: true))) do
    # Tabs: one op chain per tab — hide all panels, show one, restyle the tabs.
    button(**on_client(:click, js.hide(".panel").show("#panel-2")
      .remove_class(".tab", "active").add_class("#tab-2", "active"))) { "Tab 2" }

    # A menu that opens client-side and closes on ANY outside click (the root
    # carries the window-bound trigger above).
    button(**on_client(:click, js.show("#menu"))) { "Menu" }
    div(id: "menu", hidden: true) { menu_items }
  end
end
```

The `js` builder is immutable (each verb returns a new chain) and its
vocabulary is a fixed whitelist mirrored by the client: `show`/`hide`/`toggle`
flip the `hidden` attribute; `add_class`/`remove_class`/`toggle_class` take one
or more classes. Targets are CSS selectors resolved **within the component's
root** (nested reactive components are never touched — same ownership rule as
field collection); `:root` targets the root element itself; `global: true` on
an op escapes to the whole document. An op name the client doesn't recognize
logs a warning and is skipped — the rest of the chain still applies.

In development and test (`verbose_errors`), an op whose selector resolves to
**zero elements** also warns once per unique (op, selector, scope) — with a
targeted hint when the element exists but sits outside the op's scope: "use
`to: :root`" when the selector matches the component's own root (root-scoped
resolution never includes the root itself), or "use `global: true`" when it
matches only inside a nested reactive root or elsewhere in the document.
Production stays silent — a zero-match no-op is legitimate there.

**Attributes, focus, dispatch, and transitions.** Beyond visibility and classes,
the same chain covers the rest of the client-only vocabulary:

```ruby
button(**on_client(:click, js
  .toggle("#menu", transition: { during: "transition-opacity", from: "opacity-0", to: "opacity-100" })
  .toggle_attr(:root, "aria-expanded")   # accessible disclosure state
  .focus_first("#menu")                   # move focus into the opened menu
  .dispatch("app:menu-toggled", detail: { open: true }))) { "Menu" }
```

- **`set_attr(to, name, value)` / `remove_attr(to, name)` / `toggle_attr(to, name)`**
  mutate an attribute. The **attribute name is allowlisted, enforced twice** — at
  build time in Ruby (an offending name raises) and again in the client
  interpreter (a hand-built op is warned and skipped). Refused: **event handlers**
  (`on*` → XSS), **URL-bearing** names (`href`, `src`, `srcdoc`, `action`,
  `formaction`, `xlink:href` → a `javascript:` navigation surface), and **`style`**
  (CSS injection — use classes). The **intended surface** is class ops plus
  `hidden`, `disabled`, `open`, `selected`, and any `aria-*` / `data-*` attribute.
- **`focus(to)`** focuses the first match; **`focus_first(to)`** focuses the first
  focusable descendant of the match (e.g. the first menuitem inside an opened
  menu).
- **`text(to, value)`** sets the target's `textContent` (stringified; `nil`
  clears) — **XSS-safe by construction**, never `innerHTML`, strictly less
  powerful than `set_attr`. With `global: true` it is the **cross-root text
  escape**: paint a value into a recap node outside the component's root
  (`js.text("#sum_total", total, global: true)`).
- **`dispatch(name, to: nil, detail: {})`** emits a **bubbling `CustomEvent`** so
  another component or a plain Stimulus controller can react to a client-only
  interaction — `to:` picks the element (default: the component root), `detail:`
  is the payload.
- **`submit(to = :root)`** commits the **target's own form** via
  `requestSubmit()`: the target itself when it *is* a form, its form owner for a
  control (`input.form`, honoring a `form=` attribute), else the nearest ancestor
  form. Constraint validation runs and a **real cancelable `submit` event**
  fires, so it composes with both a native/Turbo form *and* an
  `on(:save, event: "submit")` interception. **Actor-only like focus**: allowed
  from `on_client` / `reply.js` / a reducer's `$ops`, refused in
  `broadcast_to(js:)` (a broadcast would force-submit every subscriber's form).
  Binding a submit op to the `submit` event itself raises at render — it would
  re-fire itself forever.
- **`paste_into(to)`** reads the clipboard into a field on a **user gesture**
  (issue #228): `navigator.clipboard.readText()`, then the field gets the text
  through the **normal `input` pipeline** — `.value` is set, a bubbling `input`
  event fires (compute reducers, `reactive_show`, `reactive_on_complete` all run
  exactly as if the user had typed), and the field is focused so a partial paste
  continues from the caret. Built for fields whose real `<input>` is visually
  hidden (an OTP cell UI), where right-click → Paste can't reach the editable
  input. The permission UX is the **browser's own** (Chromium prompts, Safari
  shows its paste pill); a denied/dismissed read, empty text, or a missing API
  is a **silent no-op**. `on_client` marks the trigger with
  `data-reactive-clipboard` and the controller sets `hidden = !available` on
  connect — author the trigger `hidden` and it is revealed only where the
  clipboard API exists, so a dead button never shows. The gate **owns** the
  trigger's `hidden` flag: render the trigger unconditionally and don't also
  bind `reactive_show` to it (the two passes would fight over the same
  attribute). **Actor-only like focus/submit**: refused in `broadcast_to(js:)`
  (a broadcast that reads every subscriber's clipboard would be hostile). The
  op is async fire-and-forget — chained siblings apply immediately, never
  waiting for the read.
- **`transition: { during:, from:, to: }`** on `show`/`hide`/`toggle` animates the
  visibility flip: `during`+`from` are applied, then `from`→`to` swaps on the next
  frame, and the helper classes are cleaned up on `animationend` (with a timeout
  fallback, so an element with no animation never leaves them stuck). The op chain
  is never blocked — later ops (a `focus`, a `dispatch`) run immediately.

`window:`, `once:`, and `outside:` compose exactly like `on(...)`'s event
modifiers: the dropdown above closes on any click outside the component, and
window-bound triggers never `preventDefault`, so links elsewhere keep working.

**The general autosubmit story.** With `submit` in the vocabulary, the classic
`onchange="this.form.requestSubmit()"` filter form is one declared line — no
bespoke controller, no reactive action, and Turbo Drive turns the resulting
submit into a normal visit:

```ruby
form(action: "/products", method: "get") do
  select(name: "sort", **mix(on_client(:change, js.submit("form")), data: { testid: "sort" })) do
    option(value: "name") { "Name" }
    option(value: "price") { "Price" }
  end
end
```

Use `change`-bound autosubmit for discrete controls (selects, radios,
checkboxes). For a **text** field that should commit "when the value is
complete," an unconditional `on_client(:input, js.submit)` would fire on every
keystroke — that conditional case is exactly what a reducer's
[`$ops`](#client-side-computes-reactive_compute--reactive_text) and
[`reactive_on_complete`](#declarative-completion-reactive_on_complete) are for.

**Client ops are ephemeral UI — the one contract to internalize.** Any server
re-render of the component (an action reply, a broadcast, a morph) rebuilds
from server state and resets whatever the ops toggled: the menu closes, the tab
snaps back. That is by design — the same caveat LiveView's JS commands carry.
For state that must survive a re-render (an edit mode, a selection the server
should know about), use a signed `action` instead; `on_client` is for state the
server should never care about.

**Auto-collected sibling fields — the read contract.** A reactive action doesn't
just receive its own trigger's value: the client gathers **every named control**
in the reactive root (`input[name]`, `select[name]`, `textarea[name]`, and named
rich-text/`contenteditable` editors) and merges them under the action's params,
so one action reads the whole form. Explicit `on(:act, x: …)` params win over a
collected field of the same name; collection stops at nested reactive roots (see
*Nested reactive components compose* above). Two things worth pinning down:

- **Timing — params reflect the DOM at dispatch, not a pre-event snapshot
  (issue #65).** Field values are read when the request is sent (after the
  debounce quiet period, if any), so a `change`/`input` trigger sees **its own
  field's new value and every peer's current value.** There is no capture of the
  values as they were *before* the interaction — if your computation needs a
  peer's prior value (e.g. a spill-back that folds an overflow into the edited
  field), that peer's current DOM value *is* the prior value only because nothing
  else has changed it yet. Read at dispatch time, trust the current DOM.
- **Disabled fields ARE collected (issue #66) — deliberately different from a
  native form.** A `<form>` submit omits `disabled` controls; reactive collection
  does **not** check `disabled`, so a disabled field that carries a
  computed/display value (a read-only `total` the client keeps in sync) reaches
  the action. This is intentional — it's what makes "read a computed disabled
  field" work. If you need form-submit parity (drop the disabled value), give the
  control no `name`, or make it `readonly` instead of `disabled` when you *do*
  want it collected by both paths.

**Keyboard triggers (Enter-to-submit / Escape-to-cancel).** `event:` is
interpolated straight into the Stimulus action descriptor, so any Stimulus event
string works — including its **native keyboard filters**. Pass `event:
"keydown.enter"` to fire only on Enter, `event: "keydown.esc"` for Escape — the
classic "Enter adds the row", "Escape cancels the edit" interactions. The action
runs *only* on that key, not on every keypress — no client JavaScript, no
`event.key` check of your own, and no new option to learn (it's Stimulus's own
[keyboard-filter syntax](https://stimulus.hotwired.dev/reference/actions#keyboardevent-filter)):

```ruby
# Enter in the composer adds the todo (same action as the Add button).
input(**mix(on(:add, event: "keydown.enter"), name: "title", placeholder: "New todo…"))

# Inline editor: Enter on the field saves; a separate control cancels on Escape.
input(**mix(on(:save, event: "keydown.enter"), name: "title", value: @todo.title))
button(**on(:cancel, event: "keydown.esc")) { "Cancel" }
```

The filter tokens are Stimulus's (`enter`, `esc`, `space`, `up`, `down`, a bare
letter, …). Because a keyboard trigger isn't a click, it does **not** get the
`type="button"` a click trigger does. Folding the key into `event:` keeps `key`
free as an ordinary action-param name (`on(:switch, key: "pgbus")` still passes
`key` through as a param).

> **One action per element.** Each trigger element carries a single reactive
> action (its `data-reactive-action-param`), so you can't put `on(:save, event:
> "keydown.enter")` *and* `on(:cancel, event: "keydown.esc")` on the **same**
> input — the second would overwrite the first's action name. Bind each key
> trigger to its own element (the field saves on Enter; a Cancel button — or the
> field's own blur — handles Escape), as above.

### Value-conditional visibility (`reactive_show`)

`on_client` covers the *unconditional* client-only interactions; the last gap
was **show/hide from a form field's current value** — the Alpine `x-show` /
Datastar `data-show` / Livewire `wire:show` case. `reactive_show` closes it with
ONE Ruby-native conditions language: spread it onto the element to show/hide and
declare an `if:` / `if_any:` / `unless:` condition with `where`-style values —
the generic controller toggles the `hidden` attribute from the fields' current
values on every `input`/`change`. Client-only, **no token, no POST, ever**:

```ruby
def view_template
  div(**reactive_root) do
    select(name: "mode") { shipping_options }
    div(**reactive_show(unless: { mode: "off" })) { shipping_details }

    input(type: "checkbox", name: "gift")
    div(**reactive_show(if: { gift: true })) { gift_message_field }

    select(name: "size") { size_options }
    div(**reactive_show(if: { size: %w[l xl] })) { surcharge_note }        # membership

    input(type: "number", name: "quantity")
    div(**reactive_show(if: { quantity: 10.. })) { bulk_note }             # threshold
  end
end
```

- **The value language**: a **Hash is an AND** (multiple keys ANDed), an
  **Array is membership**, a **Range is a threshold** (`10..` ≥ 10, `..10` ≤ 10,
  `...10` < 10, `10..20` between), `true`/`false` compare a checkbox's checked
  state, `nil` matches blank, and **`{ length: … }` compares the value's
  length** — exact (`{ length: 6 }`) or an Integer Range (`{ length: 6.. }`,
  `{ length: 4..8 }`). Length counts **codepoints** on both sides (Ruby
  `String#length`, client `[...value].length`), so multibyte input agrees; a
  blank field has length 0. `unless:` **negates** and composes with `if:`.
  Never an expression — every term is a declared literal, so there is no eval
  surface. A blank/non-numeric value fails a numeric term **closed** (hidden).
- **OR-of-AND** — `if_any:` takes an array of AND-hashes (`if_any: [{ director:
  true }, { shareholder: true, role: "individual" }]`), so
  `director || (shareholder && individual)` is **one flat binding**, no nested
  wrapper divs, no hand-applied distributive law.
- **First paint is computed for you** — declare `reactive_values` once
  (`def reactive_values = { mode: @order.mode, gift: @order.gift? }`) and every
  binding whose fields are all provided renders the correct initial `hidden:`
  server-side. No per-section mirror method, no flash. An explicit `hidden:`
  always wins; a per-call `values:` override merges over `reactive_values`.
- **`reactive_scope :form`** lets bindings and `reactive_values` use bare
  symbols while the client resolves `[name="form[field]"]`.
- **`disable: true`** disables a hidden section's own controls so a
  switched-away value never submits (the stale-value fix).
- **Field reads follow the collection rules**: a checkbox compares its *checked*
  state; a radio group reads the **checked** radio's value; everything else
  reads `.value`. Ownership is the usual rule — a nested reactive component's
  fields and bindings belong to the nested component.
- **Composes with computes**: a `reactive_compute` output write dispatches a
  real `input` event, so a *derived* value can drive visibility too.
- Presentational only, strictly weaker than the js ops: it reads owned fields
  and toggles `hidden` (+ optionally `disabled`) on owned elements — no
  `innerHTML`, no attribute freedom. Cross-root writes take the escape below.

**Cross-root targets (`reactive_show_targets`).** A plain `reactive_show` is
root-scoped by design — but "a mode selector reveals dependent sections
elsewhere on the page" (a nav tab, a panel in a *different* tab pane, a sticky
sidebar note) routinely puts the dependents **outside** the control's root.
`reactive_show_targets` is the declared escape, the visibility parallel of the
[cross-root text mirror](#cross-root-mirrors-mirror--painting-a-recap-outside-the-root):
the component that **owns** the field declares which outside ids it governs,
spread on the **root**, using the same `where`-style values:

```ruby
div(**mix(reactive_root, reactive_show_targets(:mode,
  "#advanced-tab"   => "advanced",            # equals
  "#advanced-panel" => "advanced",
  "#premium-note"   => %w[gold platinum]))) do  # membership
  select(name: "mode") { mode_options }
  # …
end
```

Same posture as `mirror:`: **opt-in and declared, never implicit** — a plain
`reactive_show` stays root-isolated; targets are **single id selectors only**
(a class/compound selector raises at render AND is warn-and-skipped by the
client — two-sided default-deny); values use the same vocabulary; and the
toggle is `hidden` only. The field read stays **owned** — you can only drive
outside visibility from a field the declaring root owns. A target id not on the
page is silently skipped, so a target inside an unrendered tab pane is fine.

**One call per root.** Phlex `mix` space-joins duplicate string `data:`
values, so a *second* `reactive_show_targets` call on the same root would
concatenate two JSON payloads into an unparseable attribute (the client warns
and ignores it). Several fields go in **one call** via the hash form:

```ruby
reactive_show_targets(mode: { "#advanced-tab" => "advanced" },
                      kind: { "#premium-note" => %w[gold platinum] })
```

**Multi-field targets.** A `"#id"` *key* takes a full `if:`/`if_any:`/`unless:`
conditions Hash — the same language `reactive_show` speaks — so a cross-root
target can read a **combination** of owned fields (the case that used to force
a bespoke two-field JS listener):

```ruby
reactive_show_targets(
  "#trade-warning" => { if: { type: "trade", price: ..0 } },  # type == "trade" AND price <= 0
  mode: { "#advanced-tab" => "advanced" }                     # field-keyed entries mix in the ONE call
)
```

The fold is identical to an in-root `reactive_show` (each term reads its own
field; a missing owned field reads as blank — fail-closed). Every referenced
field must be owned by the declaring root; a target whose fields are all
unowned is left alone, like the single-field skip.

### Client-only drafts (`reactive_persist`)

"Don't make me start over": a public application form, a multi-step wizard,
a long comment box — the user types, navigates away, comes back, and expects
their draft. Nothing the server needs until submit, no signed-in user to
autosave for. `reactive_persist` (#239) is the `reactive_show`-shaped answer:
a **declared, client-only** binding over the fields the root **owns**, no
token, no POST, no expression surface — the generic controller keeps a
`localStorage` draft and every hand-rolled "local save" Stimulus controller
goes away.

```ruby
class ApplicationForm < ApplicationComponent
  include Phlex::Reactive::ClientBindings     # or the full Component
  reactive_scope :apply

  def view_template
    form(action: "/applications", method: "post") do
      div(**mix(reactive_root(id: "apply"), reactive_persist(key: "village-apply", ttl: 7.days))) do
        input(**reactive_field(:name))                              # persisted
        textarea(**reactive_field(:bio))                            # persisted
        input(name: "fuckery", **reactive_persist_skip)             # honeypot — never
        input(type: "hidden", name: "apply[tz]")                    # hidden — never (default)
        button(**on_client(:click, js.persist_state(step: 2))) { "Next" }
        button(**on_client(:click, js.persist_clear)) { "Discard draft" }
        button(type: "submit") { "Apply" }
      end
    end
  end
end
```

Spread it on the **root** (`mix` with `reactive_root`), **once per root**. One
wire attr: `data-reactive-persist='{"key":"village-apply","ttl":604800,"debounce":300}'`.

- **Write** — on `input` (trailing-edge debounce, `debounce:` ms, default 300)
  and immediately on `change`; a pending write is **flushed on disconnect**, so
  a fast Turbo navigation never loses the last keystrokes. The snapshot is a
  full pass over the owned controls: radios store the checked value, checkboxes
  the checked state, `<select multiple>` an array, everything else `.value`.
- **Restore** — on connect, **first** among the client bindings, so a
  `reactive_show` section, `reactive_on_complete` (armed, never fired),
  `reactive_filter` and a `reactive_compute` root all read the restored values
  on first paint — no synthetic events. A morph or broadcast re-render is
  server truth and is **never** re-restored.
- **`restore: :blank`** (default) — a draft value lands only in a control the
  server rendered **blank**, so a 422 re-render's submitted values beat an
  older draft. `restore: :always` lets the draft win.
- **Clear** — a successful `turbo:submit-end` of the form that contains the
  root, `ttl` expiry (checked on read; default `7.days`), or `js.persist_clear`.
  A successful *reactive* action does **not** clear on its own — chain
  `reply.js(js.persist_clear)` from the action when it should.
- **`fields:`** narrows the set to declared names (scope-aware symbols):
  `reactive_persist(key: "k", fields: %i[name bio])`.
- **Never persisted**: `type=hidden/file/password/submit/button/reset/image`,
  anything carrying `reactive_persist_skip`, and a nested reactive root's
  controls. `autocomplete="off"` is **not** an implicit skip — a wizard often
  sets it form-wide. **Honeypots must opt out** (`reactive_persist_skip`) or sit
  outside the root: an invisible-captcha text input looks like any other field.
- **Rich editors** (#241) — a named `lexxy-editor`, `trix-editor` or bare
  `[contenteditable]` is drafted and restored through its **own** value
  surface: the editor's `value` getter/setter (its serialized HTML, replayed
  through the editor's own sanitizing import — Trix's `HTMLParser`, Lexxy's
  `$generateNodesFromDOM` + sanitizer), a bare contenteditable's `textContent`.
  The name is the element's `name` attribute, or — Trix in the Rails
  `rich_text_area` shape — the `input=`-paired hidden input's name (the hidden
  input itself is never a separate key). `restore: :blank` **asks the editor**
  whether it is empty (Lexxy `isEmpty`, Trix `editor.getDocument().isEmpty()`),
  so an attachment-only server body is never overwritten. An editor that hasn't
  upgraded yet at connect (Trix defines its elements in a `setTimeout`; a lazily
  imported Lexxy) is restored once `customElements.whenDefined` resolves. The
  editors' own `lexxy:change` / `trix-change` events are the keystroke signal
  for the draft write (neither editor lets its native `input` bubble) and also
  fire on restore (no native `input`/`change` is ever synthesized). Their
  toolbar chrome (Lexxy's code-language select and link `href` input, Trix's
  `trix-toolbar`) is never drafted. Put `reactive_persist_skip` on the editor
  element to opt one out.
- **State bag** — `js.persist_state(step: 2)` merges a flat hash of scalars
  into the same draft (a wizard's current step). On restore the root carries
  `data-reactive-persist-state='{"step":2}'` and dispatches a bubbling
  `reactive:persist-restored` event (`detail: { key, fields, state }`) — the
  hook for your own wizard controller to jump to the saved step.
- **Storage failures are silent** — a private window, a quota error or blocked
  storage degrades to "no draft". Under `Phlex::Reactive.debug` the controller
  prints one `console.info` naming the failure so a dev sees why nothing came
  back.

Threat model: phlex-reactive never writes markup into the DOM — native controls
are replayed via `.value`/`.checked`/`.selected`, a bare contenteditable via
`textContent`, and a rich editor through its own `value` setter (the same
sanitizing import a paste takes). A tampered draft can only produce what the
user could type or paste into that field. PII sits in this
browser's `localStorage` for `ttl`; the submit-clear and `ttl` are the
shared-computer mitigation. `persist_state`/`persist_clear` are **actor-only**
ops (refused by `broadcast_to(js:)`). See the [security page](docs/security.md).

### Client-side computes (`reactive_compute` + `reactive_text`)

Some math should feel instant with **no round trip** — a NEW, unsaved record's
running total, a live title preview, a character counter. `reactive_compute`
declares a client-side reducer (a plain JS function registered once) that runs on
`input` and writes derived values straight into the DOM. When the component also
carries `on(...)`, the debounced POST still fires and the server reply reconciles
— the compute just paints first.

```ruby
reactive_compute :preview,
  inputs: { title: :string, qty: :number },  # typed: :string raw, :number → Number
  outputs: %i[title_preview char_count]       # written with no round trip

div(**reactive_root(compute: :preview)) do
  input(**reactive_field(:title, value: @post.title))
  h2    { reactive_text(:title_preview, @post.title) }  # a text-node output
  small { reactive_text(:char_count) }                  # another text-node output
end
```

```js
// Register the reducer once at boot. Its signature is (values, { changed }).
import { setComputeReducer } from "phlex/reactive/compute"
setComputeReducer("preview", ({ title }) => ({
  title_preview: title, char_count: `${title.length}/80`,
}))
```

- **`reactive_root(compute: :name)` binds AND listens at the root.** It emits the
  compute descriptors plus the `input->reactive#recompute` delegation on the root
  element, so no field needs any per-field compute wiring. `nil` (e.g.
  `reactive_root(compute: (:preview unless @post.persisted?))`) collapses to no
  binding at all — one expression for conditional compute.
- **Typed inputs.** `inputs:` takes a **hash** to type each input: a `:number` is
  coerced through `Number` (blank/NaN → 0 — the array-form default), a `:string`
  reaches the reducer **raw** so a live text preview reads real text. The **array
  form** (`inputs: %i[a b]`) stays all-numeric and byte-identical on the wire. The
  **permit-style form** (`inputs: [:qty, title: :string]`) combines both in one
  declaration — bare symbols default to `:number`, a trailing hash types the
  exceptions.
- **`reactive_text(:name, initial)`** mirrors a value into a **text node** via
  `textContent` (XSS-safe by construction). Every reducer-result key paints any
  matching sink: an owned **field** if declared in `outputs:`, any owned
  **`reactive_text`** node by presence, or a declared **`mirror:`** id — so an
  `outputs:` entry that exists only to reach a text node is redundant (existing
  declarations keep working; it's a widening, not a breaking change). It carries
  **no `name`**, so it's never collected or POSTed as a param.
- **Reducer-less mirrors, and reactive_values seeding.** A declared **input** also
  mirrors into its own `reactive_text(:same_name)` node on every keystroke with
  **no reducer at all** — so `reactive_text(:title)` is a live field echo out of
  the box. And `reactive_text(:name)` called with **no explicit `initial`** seeds
  its first paint from `reactive_values` when the component declares one and
  covers that name — the same no-flash first-paint contract `reactive_show` uses.
- **Seed the server render.** Your `view_template` must seed each mirror with the
  same derived value the reducer would (`reactive_text(:char_count, "5/80")`), or
  a later morph repaints stale text — the same reconcile contract the whole
  new-vs-persisted split relies on.

**Reducer-emitted ops (`$ops`) — commit when complete.** A reducer's outputs
write fields and text; the reserved **`$ops`** key lets it emit a **conditional
side effect** — the missing piece that used to force a bespoke controller next
to an otherwise-declarative compute. Return an op chain (the `ops` builder
mirrors the Ruby `js` verbs — minus `paste_into`, deliberately: a reducer runs
on every input event, and a clipboard read per keystroke would spam permission
prompts — or use a raw `[[op, args], …]` array) and the
controller runs it through the **same frozen op whitelist** `on_client` uses,
as a final phase **after** the field writes, text sinks, and their dispatched
`input` events settle. The canonical one-time-code field:

```js
import { setComputeReducer, ops } from "phlex/reactive/compute"

setComputeReducer("otp", ({ code }) => {
  const digits = code.replace(/\D/g, "").slice(0, 6)
  return { code: digits, $ops: digits.length === 6 ? ops.submit() : null }
})
```

```ruby
form(action: "/verify", method: "post",
  **mix(reactive_root(compute: :otp), on(:verify, event: "submit"))) do
  input(name: "code", inputmode: "numeric", autocomplete: "one-time-code")
end
```

Typing, pasting `123-456`, or platform SMS autofill all arrive as `input`
events → the reducer normalizes, and at six digits `submit` requestSubmits the
form — which `on(:verify, event: "submit")` intercepts into **one signed action
POST**. The contract that makes this safe:

- **Rising edge, keyed on content.** The chain runs only when it **differs**
  from the previous pass's chain (including from "absent"). Returning the same
  chain again is settled — a 7th keystroke capped back to the same six digits
  can't re-submit — while a **different** chain fires again (a multi-box
  reducer advancing focus emits a new `ops.focus` target per digit). A pass
  returning `null`/no `$ops` re-arms.
- **Event-gated.** The connect/morph **seed pass arms without firing** — a form
  re-rendered with an already-complete value (a validation-error morph, a
  browser restore) never auto-fires, which is what breaks the
  submit → error re-render → re-seed → submit loop.
- **Whitelisted.** `$ops` is consumed before the write phases (never painted as
  a field/text/mirror), and unknown ops warn-and-skip while siblings apply.
- **Multi-input works with the same machinery**: declare all boxes as inputs,
  join + redistribute in the reducer (a paste into any box fans out one digit
  per box), mirror the joined value into a hidden field, advance focus with a
  per-digit `ops.focus`, and `ops.submit()` on completion. See
  `spec/dummy/app/components/split_code_component.rb` for the full six-box
  example.

When you *don't* want to auto-submit, the same slot dispatches a completion
event (`ops.dispatch("code:complete")`) for a sibling to react to, or enables
the submit button (`ops.remove_attr("[type=submit]", "disabled")`) and leaves
the commit to the user.

### Declarative completion (`reactive_on_complete`)

The `$ops` escape hatch puts the condition in the reducer; when the condition
is expressible in the [conditions language](#value-conditional-visibility-reactive_show),
`reactive_on_complete` declares the whole binding in Ruby — **zero JavaScript,
no reducer**:

```ruby
class CodeCompleteComponent < ApplicationComponent
  include Phlex::Reactive::Streamable
  include Phlex::Reactive::Component

  reactive_state :code
  action :verify, params: { code: :string }

  reactive_on_complete if: { code: { length: 6 } }, run: js.dispatch("code:complete")

  def view_template
    div(**mix(reactive_root, on(:verify, event: "code:complete"))) do
      input(name: "code")
    end
  end
end
```

The generic controller evaluates the conditions over the owned fields on every
`input`/`change` (scope-aware, same resolver as `reactive_show`) and runs the
declared ops on the **rising edge** — once, when the conditions first become
true; going false re-arms; the connect/morph pass arms **without** firing, so a
re-render with already-satisfied conditions never self-fires. The pieces:

- **Conditions** are the same `if:` / `if_any:` / `unless:` kwargs
  `reactive_show` takes — including the `length:` form above, which is what
  makes "exactly six characters" declarable.
- **`run:`** is a `js` chain (available at class level) or a raw op list
  (re-checked through the attribute allowlist). `run: js.submit` auto-commits;
  `run: js.dispatch(...)` lets a sibling `on(:action, event: "...")` turn
  completion into a signed action, as above.
- **Several bindings** coexist under names:
  `reactive_on_complete :commit, if: …, run: js.submit` — each latches
  independently; redeclaring a name overrides it (normal registry inheritance).
- Prefer `$ops` when completion needs **normalization first** (strip
  separators, cap length) — the reducer already knows the cleaned value;
  prefer `reactive_on_complete` when the raw field value is the truth.

### Cross-root mirrors (`mirror:`) — painting a recap outside the root

`reactive_text` is deliberately **root-isolated** (a nested component's nodes are
never touched — issue #15's ownership rule). But a derived value often needs to
show up in a text node that *isn't inside the computing root at all*: a read-only
recap in another tab pane, a sticky footer total. Collapsing two components into
one form-wide root just for a display mirror would be a large, risky restructure —
so the component **declares the escape** instead:

```ruby
reactive_compute :split,
  inputs:  %i[a b total],
  outputs: %i[a b],
  mirror:  { sum_a: "#sum_a", sum_total: ["#sum_total", "#footer-total"] }
```

On every compute pass, each declared mirror name is painted into its
document-wide id target(s) via `textContent`. The value comes from wherever the
pass produced it — one declaration covers all three shapes:

- a **reducer-result key** (`sum_total:` above — an *extra*, text-only output the
  reducer returns alongside its real outputs),
- a **just-written output**'s settled field value,
- a declared **input**'s identity value (works with **no reducer at all**, like
  the owned-text-node identity mirror).

A name the pass produced no value for is **skipped — a mirror never blanks a
recap**. The security posture matches the rest of the library's default-deny:

- **Opt-in and declared, never implicit.** Only the selectors in the `mirror:`
  map are ever written — a plain `reactive_text` node stays root-isolated.
- **Id selectors only.** A class/attribute/`*`/compound selector **raises at
  declare time**, and the client interpreter re-checks the same shape
  (warn-and-skip) — a hand-built attr can't widen a declared mirror into a
  page-wide selector write.
- **`textContent` only, never `innerHTML`** — XSS-safe by construction, and never
  a field/attribute/style write.

For a **server-driven** cross-root paint (from an action reply or a broadcast),
use the `text` op instead: `reply.js(js.text("#sum_total", total, global: true))`.

### Combobox keyboard navigation (`listnav:`)

A searchable list needs Arrow keys to move a highlight, Enter to pick, Escape to
close — interactions that are *ephemeral client UI state* (a highlight per
keystroke would be absurd as a server round trip). Pass `listnav:` (a CSS
selector for the option elements) to a search trigger and the generic controller
handles all of it client-side, with no bespoke Stimulus controller:

```ruby
# The search input: debounced live search + keyboard list navigation.
input(**mix(
  on(:search, event: "input", debounce: 200, listnav: "[role=option]"),
  name: "query", value: @query
))

# Each option is BOTH a listnav target (role=option) and its own reactive
# select trigger — Enter just clicks the highlighted one.
button(**mix(on(:select, name: opt), role: "option")) { opt }
```

`listnav:` appends Stimulus's native keyboard filters
(`keydown.down/up/enter/esc`) to the input's `data-action`. Arrow Up/Down move a
`data-reactive-highlighted` marker among the options **with no round trip**;
Enter **clicks the highlighted option** — so selection runs through its normal
`on(:select)` reactive action (signed, default-deny, authorized like any other);
Escape clears the highlight. Only the highlight is client-side — the selection
stays a real signed action, and the highlight is never shipped as trusted state.

### Client-side option filtering (`reactive_filter`)

`listnav:` is the keyboard half of a combobox; `reactive_filter` is the other
half: **preload the options, type to narrow — zero round trips.** For a small,
static catalog a server search per keystroke is pure latency (the data was
already known at first paint), and a bespoke hide/show Stimulus controller is
exactly the per-feature JS this gem exists to remove. Declare the filter on the
root instead:

```ruby
div(**mix(reactive_root, reactive_filter(
  :q,                               # the FIELD that drives the filter → [name="q"] (scope-aware)
  group: "[data-filter-group]",     # optional: collapse a header when all its options hide
  empty: "#no-matches"              # optional: reveal when 0 options match
))) do
  # STANDALONE keyboard nav — no action on the input, so typing never POSTs.
  # name: "q" is the field reactive_filter(:q) binds to; option: defaults to [role=option].
  input(name: "q", type: "search", **reactive_listnav("[role=option]"))

  categories.each do |category, exercises|
    div(data: { filter_group: "" }) do
      h3 { category }
      exercises.each do |exercise|
        # The haystack is server-rendered — pack in synonyms/categories.
        button(**mix(
          on(:select, id: exercise.id),
          role: "option",
          data: { reactive_filter_text: exercise.search_text }
        )) { exercise.name }
      end
    end
  end

  div(id: "no-matches", hidden: true) { "No matches" }
end
```

On every keystroke the generic controller lowercases the input's value and
toggles `hidden` on each option by a **substring match** against its
`data-reactive-filter-text` haystack (falling back to the option's own text) —
a declared literal match, never an expression, so there is no eval surface. A
group whose every contained option is hidden collapses with them; the empty
node reveals at 0 visible. Everything resolves **within this root only** and
re-applies after a morph.

It composes: `reactive_listnav` gives the input Arrow/Enter/Escape **without an
action** (Arrow keys skip filtered-out options; `on(…, listnav:)` requires a
dispatching trigger — wrong for an input that must never POST), and each option
stays its own signed `on(:select)` trigger. Only *filtering* is client-side —
selection still round-trips as a real signed action. Blank selectors raise at
render: a dead binding must fail loudly, not no-op in the browser.

**The escape hatch — a name-less input, targeted by id.** Inside a real
POST/GET form, a *named* query input submits a stray param alongside your
value. A form builder (phlex-forms' `tag_field`) therefore renders the query
input with an **id and no `name`** — which the field form can't express. Pass
`input:` (a raw CSS selector, verbatim — never re-scoped) instead of the field;
exactly one of the two per call:

```ruby
reactive_filter(input: "#user_tags_query")   # the input carries id, NO name
```

### Tag-chip input (`reactive_tags`)

The composed combobox/tags widget: preload suggestions, type to narrow, Enter or
click to add, remove chips — the classic bespoke `tags` Stimulus controller,
gone. The value is **form state** (like text in an input), never component
state: it lives in a hidden **comma-joined** field inside your form, the client
maintains it with **zero round trips**, and the surrounding form submit carries
it to the server (`tags.split(",")` on your side). Because nothing here needs a
signed action, the widget works in a token-less `ClientBindings` component too.

```ruby
div(**mix(reactive_root, reactive_tags(:tags), reactive_filter(:tag_query))) do
  input(type: :hidden, **reactive_field(:tags), value: @post.tags.join(","))

  div(data: { reactive_tags_list: true }) do        # chips render here
    @post.tags.each { chip(it) }                    # server-rendered first paint
  end
  template(data: { reactive_tags_template: true }) { chip }  # the chip markup, server-owned

  # listnav FIRST, tags_add second: Enter picks the highlighted option;
  # free text adds only when nothing is highlighted. Never submits the form.
  input(name: "tag_query", **mix(reactive_listnav, reactive_tags_add))

  SUGGESTIONS.each do |tag, haystack|
    button(**mix(reactive_tags_option(tag),          # click → add (client-only)
      data: { reactive_filter_text: haystack })) { tag }
  end
end

# One chip method serves both forms: with a tag it's the server-rendered chip,
# without it's the template prototype (the client fills text + remove param).
def chip(tag = nil)
  span(class: "chip", data: { reactive_tag: tag }) do
    span(data: { reactive_tag_text: true }) { tag }
    button(**(tag ? reactive_tags_remove(tag) : reactive_tags_remove)) { "×" }
  end
end
```

The chip list is a **client projection of the hidden field** — the field is the
single source of truth. Every change re-clones your `<template>` per tag,
writing the tag through `textContent` only (never `innerHTML` — the XSS-safe
`reactive_text` posture) and stamping the remove button's tag param. Tags dedupe
case-insensitively (first casing wins); a comma-separated paste splits into
individual tags; a declared tag containing a comma **raises at render** (it
would corrupt the joined value). An already-selected suggestion is hidden and
marked `data-reactive-tags-selected` — `reactive_filter` keeps it hidden through
re-filters — and resurfaces when its chip is removed. A server re-render/morph
re-projects the chips from the field's fresh server value, and each write
dispatches a real `input` event on the hidden field, so `reactive_dirty`,
`reactive_show`, and `reactive_compute` all see it.

The styled, form-builder-integrated version of this widget (label/errors/
theming) belongs in your form layer — these helpers are deliberately the
unstyled primitives, like `reactive_filter` before them. That form layer is
exactly who needs the **escape hatches**: a form builder's wire name is
computed **per instance** (`user[tags]`, from the builder's object name), which
the class-level `reactive_scope` compile can't express. `name:` takes the wire
name **verbatim** (never re-scoped), and the query input goes name-less,
targeted by id via `reactive_filter(input:)` — so a real form submit carries
`user[tags]` and nothing else:

```ruby
div(**mix(reactive_root(id: "user_tags_widget"),
  reactive_tags(name: "user[tags]"),               # verbatim — never re-scoped
  reactive_filter(input: "#user_tags_query"))) do  # id-targeted, name-less input
  input(type: :hidden, name: "user[tags]", id: "user_tags", value: @tags.join(","))
  # …chips/template/suggestions as above…
  input(id: "user_tags_query", type: "search", **mix(reactive_listnav, reactive_tags_add))
end
```

### Draft rows for a new parent (`reactive_nested_*`)

The "new order + line items" form: the user builds up child rows **before the
parent exists**. An unsaved parent has no GlobalID to sign, so this pre-save
window can't be a reactive collection — and every app ends up hand-writing the
same imperative JS (clone a row, renumber indexes, serialize on submit).
`reactive_nested_*` is that pattern as a primitive, the `reactive_tags`
posture: the rows are **form state**, add/remove run **entirely client-side**
(zero round trips, no token — works in a `ClientBindings` component), and the
surrounding **real form submit** posts standard Rails
`parent[assoc_attributes][<index>][field]` names, so
`accepts_nested_attributes_for` creates the parent + rows in **one request**.

```ruby
class DraftOrderForm < ApplicationComponent
  include Phlex::Reactive::ClientBindings

  reactive_scope :order   # names post as order[line_items_attributes][…]

  def view_template
    div(**reactive_root(id: "draft_order_form")) do
      form(action: orders_path, method: "post", data: { turbo: "false" }) do
        input(**reactive_field(:total, type: "number", value: "0"))

        div(**reactive_nested_list(:line_items)) { }             # rows land here
        template(**reactive_nested_template(:line_items)) { row_fields }
        button(**reactive_nested_add(:line_items)) { "Add item" }

        button(type: "submit") { "Create order" }
      end
    end
  end

  private

  # ONE row's markup, authored once. The default renders the template
  # prototype (NEW_ROW placeholder names — the client swaps in a fresh index
  # per add); pass index: to server-render an edit form's persisted rows.
  def row_fields(index: nil)
    kwargs = index.nil? ? {} : { index: }
    div(**reactive_nested_row) do
      input(name: nested_field_name(:line_items, :quantity, **kwargs), type: "number")
      input(name: nested_field_name(:line_items, :price, **kwargs), type: "number")
      button(**reactive_nested_remove) { "×" }
    end
  end
end
```

```ruby
# The model + controller side is plain Rails — the reconcile is one create:
class Order < ApplicationRecord
  has_many :line_items, dependent: :destroy
  accepts_nested_attributes_for :line_items, allow_destroy: true
end

Order.create!(params.require(:order).permit(:total,
  line_items_attributes: %i[id quantity price _destroy]))
```

Clicking add clones your `<template>` row and swaps every `NEW_ROW` in the
clone's `name`/`id`/`for` attributes for a fresh unique index (clock-seeded and
strictly monotonic — server-rendered `0..n` indexes and same-millisecond double
clicks can't collide), then focuses the new row's first field. Remove on a
draft row deletes it from the DOM — it was never persisted, so removing its
fields *is* the removal. Remove on a row carrying a hidden `[_destroy]` input
(an **edit** form's persisted row, rendered with `nested_field_name(:line_items,
:_destroy, index: i)`) marks it `"1"` and hides the row instead — Rails destroys
it on save. Several collections can share one root (everything is keyed by the
association name); nesting a collection inside another's template is not
supported.

`nested_field_name` is scope-aware (`reactive_scope :order` → the
`order[…]` wrap above). When the parent prefix is **per-instance** — a form
builder's object name, possibly itself bracketed (`"user[profile]"`) — pass
`scope:` per call instead; it's used verbatim and wins over the class-level
scope: `nested_field_name(:line_items, :quantity, scope: "order")`.

Two boundaries to respect: the DOM is the single source of truth for unsent
draft rows, so a **server re-render of the root replaces them** — keep
replace-shaped actions out of a root holding unsent rows. And once the parent
is saved, the persisted flow takes over: the same row markup renders with real
indexes, or the list graduates to a [reactive collection](#reactive-collections-addremove-rows--count--empty-state)
(`reactive_collection` + `reply.append`/`reply.remove`).

**JSON mode — one hidden field instead of `accepts_nested_attributes_for`.**
If your controller already parses a **serialized JSON param** (the app-rolled
"stuff the rows into a hidden field, `JSON.parse` on submit" pattern) rather
than nested attributes, opt the list into `as: :json` and keep your persistence
path exactly as it is:

```ruby
div(**reactive_nested_list(:line_items, as: :json)) { }   # + a hidden field to sync
# the hidden field the client keeps in sync (seed "[]" so an empty submit posts one):
input(type: "hidden", **reactive_field(:line_items), value: "[]")

# Form-builder escape hatch: name the hidden field VERBATIM (never re-scoped):
div(**reactive_nested_list(:line_items, as: :json, name: "order[line_items]")) { }
```

```ruby
# The controller stays hand-rolled — NO accepts_nested_attributes_for:
rows = JSON.parse(params.require(:order).permit(:line_items)[:line_items].presence || "[]")
order = Order.create!(total: params[:order][:total])
rows.each { order.line_items.create!(quantity: it["quantity"], price: it["price"]) }
```

Everything else is identical — the same `<template>` row, the same
`nested_field_name`, the same add/remove triggers. In JSON mode the client
mirrors the surviving rows into that one hidden field as a JSON array on every
add / remove / keystroke (the set-value + dispatch contract, so dirty tracking
and compute still see it), inferring each JSON key from the **trailing bracket
segment** of a row input's name (`order[line_items_attributes][3][quantity]` →
`"quantity"`). A removed row simply leaves the array (JSON carries no `_destroy`
marker — an absent row *is* the removal). The per-row `_attributes` names still
render but are ignored by a controller that doesn't permit them; the JSON field
is the single source of truth.

**Fill-then-add — snapshot add controls that live OUTSIDE the row.** The default
`reactive_nested_add` is *inline-edit*: it clones the template and focuses the
new row's first field, so you type INTO the row. A common alternative puts the
add controls outside the row — a preset `<select>`, a typeahead, plain inputs —
and "Add" **snapshots** those values into a new row, then clears them for the
next entry. Pass `from:` (a map of row-field → source-control selector) and
optionally `clear:`:

```ruby
input(id: "item-name",  type: "text")     # the add controls, OUTSIDE the row
input(id: "item-qty",   type: "number")

button(**reactive_nested_add(:line_items,
  from: { name: "#item-name", quantity: "#item-qty" },  # row field => source selector
  clear: true)) { "Add item" }
```

On click the client clones the template, fills each cloned-row field from its
source control's current value (matching the field by the **same** trailing
bracket-segment key inference JSON mode uses), keeps focus on the sources (so
you keep entering the next item — it does *not* steal focus into the row), and,
with `clear: true`, resets the sources (each via the set-value + dispatch
contract, so dirty tracking and compute see it). The `from:` values are raw CSS
selectors resolved within this root (`#15` ownership); a selector that resolves
nothing, or a row-field key with no matching cloned field, is skipped (the row
still adds — never a throw). It composes with **both** wire modes: the seeded
values ride the renumbered `_attributes` names on submit (`:attributes`) and the
end-of-add JSON sync serializes them (`as: :json`), with no extra wiring.

Relatedly, a **draft parent can now run real server actions too** (issue #208):
an unsaved record signs a gid-less `{c, state}` token, and the endpoint rebuilds
the component through the record kwarg's **initialize default** —
`def initialize(order: Order.new, …)` — with the declared `reactive_state`
riding the token. A component whose initialize *requires* the record kwarg
raises a guided error on the first draft action, telling you to add the default.

**Combining `on(...)` / `reactive_attrs` with your own attributes.** Both return
a hash that includes a `data:` key. Spreading them *and* passing another `data:`
(or `class:`, `id:`) would clobber it — use Phlex's `mix` to deep-merge. For the
**root**, prefer `reactive_root`, which already `mix`es id + token for you:

```ruby
# ✅ merges cleanly (data-action survives, your data-testid/class are added)
button(**mix(on(:increment), class: "btn", data: { testid: "inc" })) { "+" }
div(**reactive_root(class: "card", data: { testid: "root" })) { ... }   # id + token + your attrs

# ❌ the extra data: overwrites on()'s data:, so the action never binds
button(**on(:increment), data: { testid: "inc" }) { "+" }
```

> **The reactive root must carry `#id` (issue #48).** The server targets your
> component's `#id` and the client self-matches its next signed token by the root
> element's `id`. `reactive_attrs` does **not** emit the id — so if you put `id:`
> on a **child** instead of the `**reactive_attrs` element, the root's id is empty,
> token threading falls back to the first token in the response, and the *next*
> action silently fails with **HTTP 403**. Use `div(**reactive_root)` (it emits id
> + token on one element) so the id can't land on the wrong node; if you spread
> `reactive_attrs` directly, keep `id:` on the **same** element
> (`div(id:, **reactive_attrs)`). The controller `console.warn`s on connect when a
> reactive root has no id.

**Binding inputs to action params (drop the magic `name:`).** A field's value
travels with an action only if its `name` equals the param. Hand-writing
`name: "value"` on every input is easy to forget — the action then silently gets
nothing. `reactive_field` returns the attribute hash that carries the binding —
spread it onto any control (the trigger stays on the button, so focusing the
field doesn't dispatch and collapse edit mode):

```ruby
action :save, params: { value: :string, status: :string }

def view_template
  span(**reactive_root) do
    input(**reactive_field(:value, value: @record.name))    # <input name="value" …>
    select(**reactive_field(:status)) do                    # <select name="status">…</select>
      %w[open closed].each { |s| option(value: s, selected: s == @record.status) { s } }
    end
    button(**mix(on(:save), data: { testid: "save" })) { "Save" }
  end
end
```

`reactive_field(:value, **attrs)` returns just the attribute hash if you'd rather
spread it onto a control yourself. An explicit `name:` still wins (escape hatch).

**Editing an associated record (`accepts_nested_attributes_for`).** `nested_update!`
maps a declared nested param straight onto `<assoc>_attributes` and carries the
existing record's id, so `update_only:` matches it in place instead of building a
second `has_one` (the boilerplate that's easy to get subtly wrong):

```ruby
# Account has_one :address; accepts_nested_attributes_for :address, update_only: true
action :save, params: { address: { street: :string, city: :string } }

def save(address:)
  nested_update!(:address, address)   # update!(address_attributes: address.merge(id: @account.address&.id))
end
```

`nested_attributes(:address, address)` returns the id-merged hash without
updating, if you need to combine it with other attributes.

### Custom confirmation dialogs (`setConfirmResolver`)

`on(:action, confirm: "Really delete this?")` gates a destructive trigger behind
a confirmation. Because the reactive controller preempts the event (its own
`preventDefault` + POST), Hotwire's `data-turbo-confirm` — which routes through
`Turbo.config.forms.confirm` — never runs for a reactive trigger. So by default
the gate uses the browser-native `window.confirm` (synchronous, no dependency,
screen-reader friendly).

If your app already themes confirmations (the common Hotwire setup —
`Turbo.config.forms.confirm = (message) => Promise<boolean>`, backed by a styled
modal), reuse that exact dialog for reactive triggers with one line at boot:

```js
import { setConfirmResolver } from "phlex/reactive/confirm"

// Reuse the same themed dialog the rest of the app already uses.
setConfirmResolver((message) => window.Turbo.config.forms.confirm(message))
```

The resolver receives the `confirm:` message and returns `true`/`false` (or a
`Promise` of one). It may be **async** — the controller `await`s it, then runs
the action only on a truthy result; a falsy result (or a rejected promise — e.g.
the user dismissed the dialog) cancels the action, exactly like declining the
native prompt. The native default is always prevented up front, so a `submit`
trigger never navigates while the dialog is open.

The resolver also gets an **optional second argument** — a context object — so a
power-user override can build the string itself instead of relying on the message
alone. It always carries `{ el }` (the trigger element the confirm fired from);
on a `reactive_nested_remove` it additionally carries `{ row, fields }` (the row
element and its `{ key => value }` field map), so a themed dialog can render
row-specific detail programmatically:

```js
setConfirmResolver((message, ctx) => {
  // message is already interpolated (client-added rows resolve %{field}, see below)
  return myThemedDialog(message, { trigger: ctx.el, fields: ctx.fields })
})
```

The second argument is purely additive — a one-parameter resolver keeps working
untouched. Unset, behavior is identical to the native `window.confirm`; the
`confirm:` markup and `on(...)` API are unchanged. For per-row confirm messages
on **client-added** draft rows, the message the resolver receives is already
interpolated from the row's live field values (`confirm: "Delete '%{name}'?"` →
`Delete 'Widget'?`) — see [Draft rows for a new
parent](#draft-rows-for-a-new-parent-reactive_nested_).

### `reply` — controlling the action's reply

By default an action re-renders its component in place. To do more, **return**
`reply.<verb>` — a subject-bound builder available in every component. It governs
only the actor's HTTP reply (cross-tab updates still use
`broadcast_to(..., exclude: reactive_connection_id)`). Returning anything else
keeps the default, so existing actions are unaffected.

`reply` reads cleanly: the component is the implicit subject (no `self` to
thread) and there's no constant to qualify (it's a method, so a namespaced
component needs no alias):

```ruby
def rename(title:)
  return reply.replace.flash(:error, @todo.errors.full_messages.to_sentence) unless @todo.update(title:)
  reply.replace
end

def approve   = (@row.approve!; reply.remove)          # drop the element
def publish   = (@article.publish!; reply.redirect(article_url(@article)))  # slug changed → Turbo.visit
def add(item:) = reply.replace.stream(Totals.update(@order))               # multi-stream

# Per-field reactive editing (a "spreadsheet" grid): a debounced save fires
# while the user is still typing/tabbing. Morph in place so the focused <input>
# and its in-progress value survive the re-render (issue #28). Note the action is
# named `update`, yet `reply.morph` is unambiguous — the verb is on `reply`:
def update(name:) = (@row.update!(name:); reply.morph)

# Re-render a COMPANION element (a heading mirroring the edited name) alongside self:
def rename(value:) = (@account.update!(name: value); reply.replace.also(page_heading: @account.name))

# Update ONLY part of the component (issue #30): re-stream just the total cell,
# NOT the whole row. reply.streams emits exactly your streams plus a tiny
# token-only refresh — no full-self replace — so a sibling <input> the user is
# mid-typing in is never torn down. The signed token still rolls forward.
def update(quantity:, price:) = (@item.update!(quantity:, price:); reply.streams(Totals.update(@item)))
```

| Builder | Reply |
|---|---|
| `reply.replace` / `reply.update(morph: false)` | re-render in place (default; `replace` swaps the whole element via outerHTML, `update` swaps only the inner HTML) |
| `reply.morph` / `reply.replace(morph: true)` / `reply.update(morph: true)` | re-render in place via Idiomorph (`method="morph"`) — preserves the focused `<input>` + caret; for per-field reactive editing (`replace` #28; `update` #113) |
| `.also(target => content, …)` | **UPDATE** (inner HTML) companion elements by DOM id; `content` is a plain string (escaped) or a Phlex component. The argument *type* picks the action — pairs mean `update` |
| `.also(component, morph: false)` | **REPLACE** another Streamable component at its own `#id` (`morph: true` morphs in place). A component argument means `replace` |
| `.flash(level, content, target: …)` | append a flash; `content` is a plain string (escaped, wrapped in a level-carrying `<div>` — see [Flash levels](#flash-levels)) or a Phlex component (rendered verbatim; off-request — no Rails `flash`); target defaults to `Phlex::Reactive.flash_target` (`"flash"`) |
| `reply.remove` | remove the element (backed by `Streamable#to_stream_remove`) |
| `reply.redirect(url)` | client-side `Turbo.visit` (pass a `*_url`); rides a `reactive:visit` turbo-stream, not an HTTP 3xx |
| `reply.streams(*streams)` | **partial update** — emit exactly these streams (no full-self replace) + a tiny token-only refresh, so live inputs survive; for per-field grid editing (issue #30) |
| `.js(ops, target: …)` | also push **client DOM ops** (focus, dispatch, class/attr toggles) over a `reactive:js` stream, applied AFTER the render — `reply.morph.js(js.focus("[name=next]"))` focuses the morphed field (issue #97) |
| `.defer(component, placeholder:, morph:)` | take an **expensive segment off the actor's critical path** (issue #165) — the reply returns immediately and the real render streams to the SAME actor when ready; see [Deferred segments](#deferred-segments-replydefer--reactive_lazy) |
| `reply.pending(records, in:, job:, args:, peers:) { … }` | the action **enqueues** the work: mark the targets pending now and let **your own job** settle them when the work is actually done (issue #248); see [Async actions](#async-actions-replypending--reactive_settle) |
| `reply.with(*streams)` / `#stream(*more)` | multi-stream (self re-render still injected for the token) |

`.flash`/`.stream`/`.also` are additive on a self-replace, so the component's
signed token always refreshes. **`reply.streams`** is the exception that proves
the rule: it deliberately skips the full-self replace (so your hand-built streams
update only the targets you name) and refreshes the token via a tiny inert
`reactive:token` stream instead — the token rolls forward without re-rendering
(and clobbering) the component's live inputs.

#### Deferred segments (`reply.defer` + `reactive_lazy`)

> **Profile first.** An app-side N+1 or a missing eager-load *looks exactly
> like framework lag* — a scoreboard re-rendering on every debounced keystroke
> once "felt slow" here, and the real cause was `2 + N` queries per keystroke,
> fixed with one eager load and no gem change. Make the synchronous path cheap
> before you make it async; reach for `defer` only when a reply segment is
> **genuinely** expensive (a cross-aggregate rollup, a report, an external call).

Everything in a `reply` renders synchronously on the request thread, so one
expensive segment stalls the actor's whole interaction. `reply.defer` takes it
off the critical path — the actor's reply returns immediately and the real
HTML streams to **that same actor** the moment the render finishes:

```ruby
action :update, params: { weight_kg: :float, reps: :integer, rpe: :float }
def update(weight_kg:, reps:, rpe:)
  authorize! @set, :update?
  @set.update!(weight_kg:, reps:, rpe:)

  reply
    .streams(volume_cell_stream)                  # instant, cheap — synchronous
    .defer(SessionTotals.new(workout: @workout))  # expensive — deferred
end
```

Be honest about the trade: **defer improves the actor's reply latency and makes
time-to-full-content slightly worse** (one extra hop). It moves cost off the
critical path; it never removes it.

While the deferred render is pending, the target keeps its current (stale)
content and carries `data-reactive-defer-pending` + `aria-busy` — style the
window in pure CSS:

```css
[data-reactive-defer-pending] { opacity: .5; }
```

Options:

```ruby
reply.defer(comp)                             # keep-content default (above)
reply.defer(comp, placeholder: true)          # comp's deferred_placeholder, or a built-in shell
reply.defer(comp, placeholder: Skeleton.new)  # explicit skeleton (component, or an html_safe string)
reply.defer(comp, morph: true)                # arrival morphs in place (mode rides INSIDE the signed token)
```

`deferred_placeholder` (optional, on the deferred component) returns a Phlex
component instance, an `html_safe` string, or a plain string (escaped — data,
not markup).

Semantics you can rely on:

- **Transactional** — the directive rides the reply, which only renders after
  the action's transaction committed; a rollback or a denied action leaks no
  deferred render (and enqueues no job).
- **Actor-scoped** — the deferred render reaches only the actor; peers keep
  getting updates via `broadcast_to` (use both when both need the value).
- **Superseding** — a newer action for the same target aborts the in-flight
  deferred render; a fast typist never gets stale totals painted over fresh ones.
- **Interactive on arrival** — the streamed root carries a fresh action token.
- **Failure-visible** — a failed deferred fetch clears the pending state, sets
  `data-reactive-error="defer"`, and emits `reactive:error` with a `retry()`;
  `render?` false resolves to a 204 (pending cleared, content kept).

**Delivery** is transport-adaptive (`Phlex::Reactive.defer_transport`, default
`:auto`): a parallel authenticated fetch to `POST /reactive/defer` everywhere
(carrying a purpose-scoped, short-TTL signed identity token —
`defer_token_ttl`, default 120s; an action token is rejected at the defer
endpoint and vice versa), or — when pgbus's reactive Streams **and** ActiveJob
are present — a **durable one-shot pgbus stream** rendered by
`Phlex::Reactive::DeferredRenderJob` off the request thread
(`defer_job_queue` config; the durable replay closes the
broadcast-before-subscribe race). `:fetch` forces the fetch lane; `:stream`
requests push and degrades to fetch with a warning when the capability is
absent. Both lanes are invisible to your action code.

> **The push lane's queue lifecycle.** Each deferred segment on the push lane
> mints a durable one-shot pgbus stream. Its queue is reclaimed by pgbus's
> **age-based orphan-stream sweep** (pgbus **≥ 0.9.10**) — ensure the pgbus
> **Dispatcher is running** with `streams_orphan_threshold` set (its default).
> We do **not** drop the queue from the render job: an eager drop would destroy
> a not-yet-consumed message and reopen the very broadcast-before-subscribe race
> the durable lane exists to close. On pgbus ≤ 0.9.9 the sweep only reaped
> *empty* queues (which a durable stream never becomes), so a one-shot queue
> leaked — upgrade to ≥ 0.9.10, or stay on the pull lane
> (`defer_transport = :fetch`, the universal default, which needs no cleanup).

**Security of the defer token.** The defer endpoint re-renders the real
component, whose fresh root carries a normal (non-expiring) action token — so a
defer token is, within its TTL, a render of that identity and a path to that
identity's action token. What bounds the damage in every case: **the signature
proves identity, not permission** — the harvested action token is useless
against `authorize!` in the action, which re-checks the *current* actor.
Authorize every mutating action; the token, defer or otherwise, is never the
authority.

The two defer-token channels are bound differently, by their leak surface:

- **`reply.defer` tokens** ride an **action's HTTP response** (which can transit
  a logging proxy, a shared HAR, an APM that captures bodies) — the real
  cross-infrastructure leak vector. They are **actor-bound**: signed under the
  requesting session (`Phlex::Reactive.defer_binding_for(request)`, the
  persisted session id by default — override to bind to your own actor identity,
  e.g. a user id), so a leaked one can't be redeemed in another session.
- **`reactive_lazy` shell tokens** live in the **page HTML the actor already
  fetched** over their own session (a small leak surface) — and *can't* be
  actor-bound anyway, because the shell renders on a fresh visit before the
  session exists (Rails establishes it during that response). They are minted
  **unbound**; the TTL + `authorize!` are their bound.

Apps with no persisted session (the `ActionController::Base` default, a
token-auth API) mint every defer token unbound — there too the TTL +
`authorize!` are the whole bound. Set `Phlex::Reactive.base_controller_name` to
a session-bearing controller, or override `defer_binding_for`, to bind
`reply.defer` tokens to your actor identity.

**Lazy initial mount** — the same machinery for the *first* render
(Livewire's `#[Lazy]`): declare `reactive_lazy` and the page ships the
placeholder shell; the client fetches the real content on connect. Every
reactive-machinery render (an action's self-replace, broadcasts, the defer
endpoint) stays REAL, so actions never pay two round trips:

```ruby
class SessionTotals < ApplicationComponent
  include Phlex::Reactive::Component

  reactive_record :workout
  reactive_lazy                       # first render = placeholder shell
  # reactive_lazy tag: :tr            # for a <tr>/<li> root the shell must match

  def deferred_placeholder = TotalsSkeleton.new   # optional
end
```

The lazy shell's `<div>` root would be invalid inside `<tbody>`/`<ul>`, so a
component whose real root is a `<tr>`/`<li>` sets `reactive_lazy tag: :tr` (etc.)
to ship a matching shell element. The client re-fetches the real content both on
connect AND after a Turbo page-refresh **morph** (which re-shows the shell while
keeping the element connected), so a lazy component survives a `turbo:reload`.

> **One edge case:** a `reply.defer(placeholder:)` shell (the action-driven,
> not page-mount, form) carries no token of its own — the transient directive
> owns its delivery. If a page is snapshotted by Turbo mid-defer and later
> restored from cache, that placeholder can appear stuck (the directive that
> would have filled it is long gone). It self-corrects on the next action;
> deferred **content** is never lost server-side. Lazy mounts (which carry the
> token on the shell) don't have this — they re-fetch on restore.

#### Flash levels

The level reaches the wire (issue #77). **String** content is wrapped in a
level-carrying `<div>`, so `:error` and `:notice` are styleable:

```html
<div class="reactive-flash reactive-flash--error" data-reactive-flash-level="error">
  Save failed
</div>
```

Style against `.reactive-flash--{level}` (the class) and hook scripts/tests on
`data-reactive-flash-level` (the data attribute). The string keeps the same
injection contract as before, applied inside the wrapper: a plain string is
HTML-escaped (a model value can't inject markup); an `html_safe` string passes
verbatim.

Prefer your own markup? Two escape hatches:

```ruby
# 1. Pass a Phlex component as the content — rendered VERBATIM, no wrapper
#    (you own the markup entirely, including the level styling):
reply.replace.flash(:error, Alert.new(level: :error, message: msg))

# 2. Or configure a flash component ONCE — string flashes render through it;
#    component content still bypasses it. flash_component is an app-owned
#    CALLABLE (issue #182): it maps (level, content) to your component —
#    the gem never guesses kwargs:
Phlex::Reactive.flash_component = ->(level, content) { MyFlash.new(level:, content:) }   # default nil → the built-in wrapper
```

#### Server-pushed client ops (`reply.js` + `broadcast_to(js:)`, issue #97)

Sometimes the server needs the client to do something other than swap HTML —
focus the next field after a save, dispatch an app event to a toast host, add an
unread badge — WITHOUT re-rendering to make it happen. `reply.<verb>.js(ops)`
chains a `reactive:js` stream carrying declared client DOM ops (the same `js`
builder as [`on_client`](#client-only-ops-on_client--js--zero-round-trips))
onto any reply. The op stream rides **after** the render streams, so a focus op
sees the freshly rendered/morphed DOM:

```ruby
def save(title:)
  @todo.update!(title:)
  # Morph in place, THEN focus the next field + tell a toast host we saved:
  reply.morph.js(js.focus("[name=next_field]").dispatch("app:saved", detail: { id: @todo.id }))
end
```

`target:` scopes op resolution on the client; it defaults to the bound
component's id for `replace`/`morph`/`update` (so `@root` and component-relative
selectors just work), and to document-scope for a subject-free `reply.with`.
`global: true` on a single op opts it out of the target scope to document-wide
resolution — `reply.morph.js(js.text("#sum_total", total, global: true))` paints
a recap node outside the component while the morph stays root-targeted.

The same ops broadcast to **every** subscriber of a stream over the usual
transport (Action Cable **or** pgbus) — a background nudge to all viewers:

```ruby
# In a model/job: light up the bell in every viewer's tab, minus the actor's own.
Notifications::Badge.broadcast_to(user, :alerts,
  js: js.add_class("#bell", "has-unread"), exclude: reactive_connection_id)
```

`broadcast_to` with `js:` **refuses the actor-only ops** (`focus`/`focus_first`/
`submit`/`paste_into` raise `ArgumentError`): broadcasting focus would steal it
in every subscriber's tab, a broadcast submit would force-submit every
subscriber's form, and a broadcast clipboard read would be hostile — these
belong to the actor's own reply or gesture. Everything else is a fair broadcast
(class and attribute toggles, `text`, `dispatch`). As with `on_client`, the ops are
whitelist-interpreted client-side — an unknown op warns and is skipped — and the
ops attribute is HTML-escaped, so a value can't break out of it. `reactive:js`
is not a self-render: it never counts toward the token refresh, so the reply's
signed token still rolls forward exactly as it would without the ops.

> **Ephemeral by design.** Like `on_client`, server-pushed ops are transient UI:
> the next server re-render of the component resets whatever they toggled. State
> that must survive a re-render belongs in a signed `action`, not an op.

#### Record-authorized, transient-state actions (issue #64)

A `reactive_record` component isn't obligated to persist or broadcast — the
record can be there purely for **identity + authorization** while the action's
real job is to recompute **live, unsaved form values** the user is mid-edit. The
record is re-located and instantiated on each action (`from_identity`), never
auto-saved and never auto-broadcast; persistence and cross-tab broadcast are both
opt-in (you call `record.update!` / `broadcast_to` yourself). Pair that with
`reply.streams` and you get a first-class "authorize via the row, compute over
the params, stream a partial update, touch neither the DB nor peer tabs" action:

```ruby
class Invoice::PaymentFields < ApplicationComponent
  include Phlex::Reactive::Component

  reactive_record :invoice   # identity + authorization ONLY — not persisted here
  action :rebalance, params: { invoice: { field_a: :integer, field_b: :integer,
                                          field_c: :integer, total: :integer } }

  def rebalance(invoice:)
    authorize! @invoice, :update?          # the token proves identity, not permission
    result = recompute(invoice)            # pure computation over the collected params
    reply.streams(*set_value_streams(result))  # NO persist, NO broadcast
  end
end
```

This is deliberate, not a misuse: `reply.streams` is exactly the reply for "emit
these targeted updates, roll the token forward, and leave everything else — the
DB, the other tabs, the sibling inputs the user is typing in — untouched."
Broadcasting is deliberately omitted so peer tabs with their own in-flight edits
aren't clobbered. Authorize the record as always — identity is never permission.

> **Under the hood.** `reply.<verb>` returns a `Phlex::Reactive::Response` — the
> immutable value object the endpoint reads. `reply` is the ONE documented door
> (issue #182): the old `Phlex::Reactive::Response.replace(self)` class verbs
> are removed and raise a guided `ArgumentError` naming the `reply.<verb>`
> rewrite; treat `Response` as an internal detail.
> **`html:`/`content` escaping.** A plain string is **HTML-escaped** by Turbo, so
> `html: @account.name` is safe even for user-supplied values. To emit intentional
> markup, pass a **Phlex component** (`html: Heading.new(name: @record.name)`) —
> rendered and auto-escaped through the renderer — or an `html_safe` string for
> raw HTML you control.

### Failure UX & lifecycle events

The generic controller dispatches three bubbling, composed `CustomEvent`s
around every action round trip, so an app can toast an error, instrument
latency, veto a dispatch, or build retry UI **without forking the controller**:

| Event | When | `event.detail` |
|-------|------|----------------|
| `reactive:before-dispatch` | after the trigger's `preventDefault`/`confirm:`, **before** debounce/enqueue | `{ action, params, element }` — cancelable: `event.preventDefault()` skips the round trip entirely (nothing is scheduled) |
| `reactive:applied` | after the response's token was captured and the streams were handed to `Turbo.renderStreamMessage` | `{ action, params, html }` |
| `reactive:error` | in every failure branch of the round trip | `{ action, params, kind, status?, body?, retry }` |

`reactive:error`'s `kind` tells you **what** failed:

| `kind` | Meaning | Extra detail |
|--------|---------|--------------|
| `redirected` | the POST was redirected (an auth `before_action` / CSRF guard bounced it) | `status`, `retry` |
| `http` | non-2xx response (403 default-deny/authorization, 400 bad token, 404 record gone, 500 …) | `status`, `body`, `retry` |
| `content-type` | 200, but not a turbo-stream (an HTML error page, a misconfigured route) | `status`, `retry` |
| `timeout` | the request took longer than the configured window (default 30s) and was aborted — the server may or may not have finished | `retry` |
| `offline` | the browser was offline (`navigator.onLine === false`) when the action fired — the fetch was never sent | `retry` |
| `network` | `fetch` itself rejected (DNS, connection reset, an interface drop mid-flight) — the server never saw the request | `retry` |
| `apply` | the server processed the action successfully, but something AFTER the fetch threw (a malformed response, a Turbo render error) | no `retry` |

`apply` covers a throw in the controller's own post-fetch code — not a
throwing listener on `reactive:applied` itself. Per the DOM spec,
`EventTarget#dispatchEvent` never propagates a listener's exception back to
its caller (it's reported to the console instead), so a listener that throws
can't surface as `reactive:error` at all — it just logs and the round trip is
otherwise unaffected.

`detail.retry()` re-enters the controller's request queue: it re-reads the
**freshest** signed token and re-collects the component's fields at send time,
so nothing stale is replayed. It fires no second `reactive:before-dispatch`
(one veto per user gesture), and it no-ops with a `console.warn` once the
component has left the DOM. The existing `console.error` logging is unchanged —
the events add hooks, they don't replace the log.

**`kind: "apply"` carries no `retry()` at all** — by the time this fires the
server has already completed the mutation, so retrying would re-POST an
action that already succeeded (potentially a non-idempotent one). Every kind
EXCEPT `apply` is retriable.

#### Request timeout (`kind: "timeout"`)

A server that never responds used to wedge a component's request queue forever
(each action chains on the previous one) — the spinner never cleared and every
later action froze. Now the fetch is bounded by `AbortSignal.timeout`: after the
window (default **30 s**) it aborts, fires `reactive:error` `kind: "timeout"`,
and the queue advances so the component keeps working. Configure the window with
a page-stable meta (app-authored, following the same pattern as the action path):

```erb
<meta name="phlex-reactive-timeout" content="15000"> <%# 15s #%>
```

> **Non-goal — no automatic replay.** A timed-out POST **may have succeeded
> server-side** (the server just answered too late). phlex-reactive never
> auto-replays a request, and even a manual `retry()` can double-apply a
> non-idempotent action. Make retryable actions idempotent, or gate your retry
> UI accordingly.

#### Offline (`kind: "offline"`)

When the browser is offline (`navigator.onLine === false`) at send time, the
action short-circuits **before the fetch** — the edit is never half-sent — and
fires `reactive:error` `kind: "offline"` with a `retry()`. The check lives at the
network boundary, so a request that enqueued while online but reaches the wire
after a connection drop is reported as `offline`, not `network`.

`phlex-reactive` also mirrors `data-reactive-offline` onto `<html>` whenever the
browser goes offline (kept in sync by the `online`/`offline` events) — a **pure
CSS hook**, zero app JS:

```css
[data-reactive-offline] .save-button { opacity: .5; pointer-events: none }
[data-reactive-offline] .offline-banner { display: block }
```

```js
// Auto-retry a specific action when the connection returns:
document.addEventListener("reactive:error", (e) => {
  if (e.detail.kind === "offline") {
    addEventListener("online", () => e.detail.retry(), { once: true })
  }
})
```

#### Latency simulator (development aid)

On localhost the click→morph round trip is **~5 ms**, so the pending affordances
you just wired — `aria-busy`, `disable_with:`, `busy_on`, optimistic hints —
flash by too fast to actually *see* while developing or demoing them. That's the
same problem LiveView solves with `liveSocket.enableLatencySim(ms)`.

`phlex-reactive` ships the equivalent. Because importmap module exports aren't
reachable from the DevTools console, the two functions are exposed on a
`window.PhlexReactive` handle — but **only** when your layout opts in with a
development-gated meta:

```erb
<%# app/views/layouts/application.html.erb, inside <head> — DEVELOPMENT ONLY %>
<%= tag.meta(name: "phlex-reactive-env", content: "development") if Rails.env.development? %>
```

Then, from the browser console:

```js
PhlexReactive.enableLatencySim(400)   // delay EVERY action by 400ms
// …click around; aria-busy, spinners, disable_with, optimistic hints are now visible…
PhlexReactive.disableLatencySim()     // back to full speed
```

The delay is read live before each fetch (so toggling takes effect on the very
next action, no reload) and persists to `sessionStorage` — it clears when the tab
closes, so you can't accidentally leave it on across sessions. A one-time console
banner reminds you while it's active.

Without the meta there is **no global handle at all** and the per-request read
short-circuits on a `null` — **zero production surface**. It's purely a
development convenience, gated by markup you author.

The events bubble from the component's root element (or from `document` when
the root was detached by the failing round trip), so they compose with plain
Stimulus listening — a global toaster is one attribute on an ancestor:

```html
<body data-controller="toast" data-action="reactive:error->toast#show">
```

```js
// toast_controller.js
show(event) {
  const { kind, status, retry } = event.detail
  this.flash(`Action failed (${kind}${status ? ` ${status}` : ""})`, { onRetry: retry })
}
```

Or veto/instrument at the document level:

```js
document.addEventListener("reactive:before-dispatch", (event) => {
  if (offline) event.preventDefault()           // cancel: nothing is enqueued
})
document.addEventListener("reactive:applied", ({ detail }) => {
  metrics.count(`reactive.${detail.action}.ok`)
})
```

One honest caveat on timing: `reactive:applied` means the turbo-streams were
**handed to Turbo** — `renderStreamMessage` applies them asynchronously, so the
DOM mutation may complete a tick later. If you need post-morph timing, listen
to Turbo's own events (`turbo:before-stream-render` and friends).

#### Showing the user a failure (not just the console)

The events above are the *hook* — but a user who just wants to see "that
didn't work" shouldn't have to write a toast controller. There are three
built-in ways to surface a failure, cheapest first:

**1. In-action validation replies (already works).** For a failure your action
*knows about* — a validation error, a business rule — return a flash directly.
It renders at **200** (a normal reply, not an error):

```ruby
def rename(title:)
  return reply.replace.flash(:error, "Title can't be blank") if title.blank?
  @todo.update!(title:)
end
```

**2. `Phlex::Reactive.error_flash` — server-rendered flashes on endpoint
failures.** For the failures the *endpoint* catches (bad token, default-deny,
authorization, missing record — the 400/403/404 rescue paths), set a lambda and
every one renders a turbo-stream flash the user sees, at the **same status** it
already returns (statuses never change):

```ruby
# config/initializers/phlex_reactive.rb
Phlex::Reactive.error_flash = ->(kind) { "Something went wrong (#{kind})." }
```

The client now **renders non-OK turbo-stream bodies** (previously it read the
body only for the console and discarded it), so an `error_flash` — or a plain
controller replying `status: :unprocessable_entity` with a turbo-stream flash —
lands in your flash region. The failing component's root also gets
`data-reactive-error="<kind>"`, so you can style it in **pure CSS** with zero JS,
and the next successful action clears it:

```css
[data-reactive-error] { outline: 2px solid var(--danger); }
```

> **Note.** A 400 (invalid token) reply never refreshes the client's held token
> — the identity token is not a nonce, it stays retry-valid. The client only
> adopts a fresh token from a body that re-renders *this* element's id, so a
> foreign/error body can't swap it out.

**3. Offline fallback (no server to render anything).** A `network` failure
reached no server, so there's nothing to render. Opt in with a server-rendered
`<template>` in your layout — on a network failure the client clones it into the
flash region (it's your trusted markup, cloned verbatim — no client templating):

```erb
<template data-reactive-error-flash>
  <div class="reactive-flash reactive-flash--error">You appear to be offline.</div>
</template>
```

#### Self-dismissing flashes (`dismiss_after:`)

A flash that never cleans itself up piles up. Pass `dismiss_after:` (ms) and the
flash removes itself after the timeout — driven by a **document-level** handler,
so it self-cleans both reply-delivered and **broadcast-delivered** flashes (the
flash container is a plain host-app div with no controller attached):

```ruby
reply.replace.flash(:error, "Couldn't save — try again", dismiss_after: 4000)
```

It wraps string content with `data-reactive-dismiss-after="4000"`; a verbatim
Phlex component owns its own lifecycle and is left untouched.

### Reactive collections (add/remove rows + count + empty-state)

An add/remove-row list — line items, attachments, tags, comments, a
notifications list — is one of the most common reactive surfaces, and every one
re-implements the same orchestration by hand: append the row to the right
container, remove it on delete, keep a **count badge** in sync, and swap an
**empty-state** in/out as the list crosses 0↔1. `reactive_collection` declares
that contract **once** on the container so each action is a single call.

Declare the collection on the container component, then `reply.append` /
`reply.prepend` / `reply.remove` in the actions:

```ruby
class NotificationsList < ApplicationComponent
  include Phlex::Reactive::Component

  reactive_collection :notifications,
    item: NotificationRow,        # the per-row Streamable component
    container: "notifications",    # the DOM id rows live in
    count: "notifications-count",  # optional companion id (the size badge)
    empty: NotificationsEmpty,     # optional empty-state component
    size: -> { Todo.count }        # resolves the live size (re-counted, never client state)

  action :add, params: {title: :string}
  action :dismiss, params: {id: :integer}

  def add(title:)
    todo = Todo.create!(title:)
    reply.append(todo, to: :notifications)   # append row + bump count + clear empty-state
  end

  def dismiss(id:)
    todo = Todo.find(id)
    todo.destroy!
    reply.remove(todo, from: :notifications)   # remove row + bump count + restore empty-state at 0
  end

  # view_template renders the count, the container <ul>, and the empty-state on
  # first paint — the same components the helper streams in/out on each delta.
end
```

| Builder | Reply (one `Response`) |
|---|---|
| `reply.append(model, to: name)` | append the row into the container + update the count + remove the empty-state when the list crosses 0→1 |
| `reply.prepend(model, to: name)` | as `append`, but the row goes to the top |
| `reply.remove(model, from: name)` | remove the row by its `dom_id` + update the count + append the empty-state back when the list crosses →0 |

- **`size:` is the source of truth** — it's *re-counted* server-side after the
  mutation, so the badge and the empty-state are correct-by-construction (no
  off-by-one, no client-held count). `count:`, `empty:`, and `size:` are all
  optional: omit them and only the row stream is emitted.
- **Repeated add/remove just works** — each reply rolls the **container's** signed
  token forward (via the inert `reactive:token` refresh), so the second click from
  the list root is accepted. Without this an add/remove list would be add-once-only
  (correct on the first click, silently rejected after); the helper bakes the
  refresh in so you never hit it.
- **`remove` takes the record or its `dom_id` string** — a just-destroyed
  ActiveRecord still answers `dom_id` correctly, so `reply.remove(todo, from: :items)`
  works; pass the raw id only if your row `#id` matches `ActiveRecord::RecordIdentifier`.
- **Reply governs the actor's HTTP response only.** For a *cross-tab* live list,
  broadcast the delta with `NotificationsList.broadcast_collection_to(*keys,
  container: self, in: :notifications, append: model, exclude: reactive_connection_id)`
  — that emits the row **plus** the count companion **plus** the empty-state
  toggle, through the same decisions the reply path uses. (Plain
  `broadcast_to(append:)` still works and still emits the **bare row**: it has no
  container instance, so it cannot resolve the declaration or run `size:`.)
- **When the work is asynchronous**, an action that merely enqueues it cannot
  reply with a delta at all — the reply renders before the job touches the
  database. Use [`reply.pending`](#async-actions-replypending--reactive_settle)
  and let the job settle the row.

### Async actions (`reply.pending` + `reactive_settle`)

An action that **does** the work can reply honestly. An action that
**enqueues** the work cannot — and until issue #248 every app worked around it
the same way.

The endpoint runs your action inside a transaction and renders the reply
*there*, while the queue adapter publishes on **commit**. So any `reply.morph`
after an enqueue renders from a database the job has not touched yet, and is
*guaranteed* to draw the pre-job world — rows still present, buttons still live,
counts unchanged — sitting right beside the "Queued 177 transfers" flash the
same reply emitted:

```ruby
def restore_all
  count = BatchRestoreService.call(bulk_payment: @bulk_payment)   # fans out N jobs
  reply.morph.flash(:notice, "Putting #{count} back…")            # renders the PRE-job world
end
```

The usual fix is a `queued:` kwarg threaded into every row component with a
second render branch, a `@queued_*` flag on the container, and the header
button's count forced to `0` — ~60 lines of identical bookkeeping per screen.
And it still never tells the operator the **outcome**: the page says "Queued"
forever until someone reloads.

`reply.pending` replaces all of it:

```ruby
class ReconcileQueue < ApplicationComponent
  include Phlex::Reactive::Component

  reactive_collection :unreconcilable,
    item: TransferRow, container: "unreconcilable",
    count: "unreconcilable-count", empty: NothingToReconcile,
    size: -> { @bulk_payment.transfers.unreconcilable.count }

  action :re_execute, params: {transfer_id: :integer}
  action :restore_all

  # ONE record — the job settles it, and the subscription tears itself down.
  def re_execute(transfer_id:)
    transfer = @bulk_payment.transfers.re_executable.find(transfer_id)
    authorize! transfer, :update?
    reply.pending(transfer, in: :unreconcilable, job: ReExecuteJob, args: [transfer.id])
  end

  # A FAN-OUT — the enqueue lives in the block, so the service object's own
  # perform_later calls capture the settle handle too.
  def restore_all
    authorize! @bulk_payment, :update?
    restorable = @bulk_payment.transfers.restorable.to_a
    reply.pending(restorable, in: :declined, peers: true) do
      BatchRestoreService.call(bulk_payment: @bulk_payment)
    end.flash(:notice, "Putting #{restorable.size} back…")
  end
end
```

and the job settles it when the work is **actually** done:

```ruby
class ReExecuteJob < ApplicationJob
  include Phlex::Reactive::Settles

  def perform(transfer_id)            # signature UNCHANGED
    transfer = Transfer.find(transfer_id)
    result   = Transfers::ReExecuteService.call(transfer:)

    reactive_settle do |s|
      if result.success?
        s.remove(transfer)                     # row + count + empty-state
      else
        s.replace(transfer)                    # back to actionable
        s.flash(:alert, result.error)          # the operator learns the outcome
      end
    end
  end
end
```

and the case that motivated the whole thing — work that moves a record between
two lists — is one call:

```ruby
reactive_settle { |s| s.move(transfer, from: :declined, to: :unreconcilable) }
```

#### What the reply actually does

`reply.pending` deliberately does **NOT** re-render the container (that is the
bug). It emits:

1. a `data-reactive-pending="true"` + `aria-busy="true"` marker on every target,
   over the existing `reactive:js` op lane — style it in one CSS rule:

   ```css
   [data-reactive-pending] { opacity: .5; pointer-events: none; }
   ```

2. **one** subscription directive, anchored on the container, opening a
   single durable one-shot stream that **all N settles share**;
3. an inert `reactive:token` refresh, so the container's signed token rolls
   forward and the list is not act-once-only.

| `reply.pending(...)` | |
|---|---|
| `records` | one record, an enumerable of records, or built Streamable components |
| `in: :name` | the `reactive_collection` the records live in — how their row DOM ids *and* the count/empty-state bookkeeping are resolved (required for records) |
| a block | your enqueue. **Anything ActiveJob-enqueued inside it captures the settle handle**, including from a service object |
| `job:` / `args:` | sugar for the common case. `args:` is an Array (one record) or a Proc called per record (`args: ->(r) { [r.id] }`); omitted means `perform_later(record)` |
| `peers: true` | also broadcast each settle to the container's record stream, so a second operator watching the same batch sees it. **Default is actor-only**, matching `reply.defer` |

| `reactive_settle` yields a settle builder | |
|---|---|
| `s.replace(record)` | re-render the row in place (no count churn — a replace moves no boundary) |
| `s.remove(record, from: :name)` | row + count + empty-state restore. `from:` defaults to the collection `reply.pending` named |
| `s.append(record, to: :name)` / `s.prepend` | row + count + empty-state clear |
| `s.move(record, from:, to:)` | ordered remove-then-append between two collections |
| `s.count(:name)` | refresh only the count companion |
| `s.flash(level, content)` | tell the operator the outcome |
| `s.js(ops)` / `s.streams!(*raw)` | the `reply.js` / `reply.streams` escape hatches |

#### The rules that make it safe

- **The handle rides ActiveJob metadata, not `perform`'s arity.** `reply.pending`
  installs it in a thread-local and runs your enqueue inside it;
  `Settles#serialize` copies it into the job's metadata. So **every other caller
  of the same job — a nightly sweep, a webhook — keeps working unchanged**, and
  `reactive_settle` is simply a no-op there. That is load-bearing: these jobs
  almost always have non-UI callers.
- **A job that raises still clears the pending state — when it can attribute
  it.** The `job:`/`args:` form enqueues one job per record and narrows each
  job's handle to *that record's* target, so a failure clears exactly its row
  and the container, then re-raises for your retry policy. The **block** form
  cannot be narrowed (the gem cannot map an arbitrary enqueue back to a record),
  so a failure there clears nothing and logs why — un-dimming 176 rows that are
  still working would be a worse lie. Those markers clear at `finish: true`.
  The subscription is deliberately **not** torn down on failure — a retry must
  still be able to reach the actor.
- **Finishing clears every target, not just the container.** A settle that only
  flashes emits no row stream, so nothing swaps that row's node — the finish
  sweep is what removes its markers.
- **ONE stream key per `reply.pending` call.** A durable broadcast to a
  never-seen key creates a real PGMQ table (reclaimed by pgbus's hourly orphan
  sweep at a 24h threshold), so a key per record would leave 177 tables sitting
  for a day and open 177 SSE connections. All N settles share one key and one
  subscription.
- **Teardown is therefore explicit.** Because the key is shared, tearing down on
  the *first* arrival would cut off the other N−1. `reactive_settle` finishes
  automatically when `reply.pending` marked exactly **one** target; a fan-out
  passes `finish: true` from whatever knows it is last (a `Pgbus::Batch`
  `on_finish` callback, or the final job of a staggered sequence). Until then
  the subscription is superseded by the container's next `reply.pending` or
  closed when the page unloads.
- **`reply.pending` needs the defer PUSH lane**
  (`Phlex::Reactive.settle_capable?` — pgbus reactive Streams + `SignedName` +
  ActiveJob, and `defer_transport` not forced to `:fetch`). A settle has no pull
  fallback: the client cannot poll "is the job done yet". **Without it,
  `reply.pending` degrades rather than breaks** — your enqueue still runs, no
  handle is installed, and **no pending markers are emitted**, so the UI shows
  the pre-job world (today's behavior) instead of a shimmer that could never
  resolve. A one-time warning says so.
- **The pgbus CLIENT must be on the page too.** The server picks the push lane on
  *server-side* capability alone. If the browser has no `<pgbus-stream-source>`
  custom element registered, `reply.defer` degrades to its fetch token — but a
  settle has no fetch lane, so the subscription never opens and the pending
  markers would sit there. The client logs a loud console error naming the cause.
  Load pgbus's client wherever you use `reply.pending`; it is the same
  prerequisite the defer push lane already has.
- **Authorization is still yours.** `reply.pending` signs the *container's*
  identity so the job can rebuild it; that is not permission to act. `authorize!`
  in the action, exactly as everywhere else.
- **One `reply.pending` per container, per reply.** Every pending segment emits a
  directive targeting the container's id, and the client keys subscriptions by
  target — so a second call would supersede the first and orphan its jobs. The
  second call raises. Mark every target in one call; the settle names its own
  collection (`s.remove(record, from: :name)`).
- **Peer delivery is best effort.** If a peer broadcast fails after the actor's
  message already went out, the job is *not* failed — retrying it would re-run
  `perform` and send the actor's settle (and its flash) a second time. The
  failure is logged instead.

#### Broadcasting a collection delta to peers

`broadcast_to(append:)` emits the **bare row** — it has no container instance,
so it cannot resolve the declaration or run the size resolver. Its collection
counterpart does:

```ruby
ReconcileQueue.broadcast_collection_to(@bulk_payment, :transfers,
  container: self, in: :unreconcilable, remove: transfer,
  exclude: reactive_connection_id)
```

`row:` carries the row component's extra init kwargs — pass the same ones the
actor got, or a peer whose row has a required kwarg raises instead of rendering.
A `remove:` may be a record or an already-built dom-id string, matching
`reply.remove(id, from:)`.

Row **plus** count companion **plus** empty-state toggle, through the same
`Phlex::Reactive::Collections` decisions the reply path uses — so the two can
never drift. `coalesce:` (default `Phlex::Reactive.settle_coalesce_window_ms`,
50 ms) applies to the **aggregate** streams only: the count and empty-state are
idempotent replaces of stable targets, so a 177-row fan-out collapses to a
handful of them. The **row** stream is never coalesced (an append is not
idempotent). Coalescing needs pgbus with
[zoolutions/pgbus#465](https://github.com/zoolutions/pgbus/issues/465); on
anything older the window is ignored and every aggregate goes out — chattier,
equally correct.

#### Settle configuration

| Setting | Default | Purpose |
|---|---|---|
| `Phlex::Reactive.settle_coalesce_window_ms` | `50` | Window for the aggregate (count / empty-state) streams on the peers path. |

There is deliberately **no** `settle_token_ttl`. A settle has no pull lane for a
token to govern — the client cannot poll "is the job done yet", and redeeming
such a token at the defer endpoint would render the *pre-job* component, i.e.
the exact bug `reply.pending` fixes. The settle's wait is bounded by the job,
not by a TTL.

### Effects — animate enter/exit/update (opt-in)

Reactive updates land instantly and invisibly: a removed row pops out of
existence, an appended row pops in, a cross-tab change gives no cue. Effects
make the reactivity *visible* — rows fade/slide in and out, updates flash —
with zero app JS. Strictly **opt-in at three levels**, most specific wins:

```ruby
# 1. GLOBAL — setting it is the opt-in AND the app-wide default set:
Phlex::Reactive.effects = true   # { enter: :fade, exit: :fade, update: :highlight }
Phlex::Reactive.effects = { enter: :slide, exit: :fade, update: :highlight }

# 2. PER COMPONENT — refine or opt out (works standalone too; declaring on a
#    component opts it in even without the global switch):
class Notifications::Row < ApplicationComponent
  reactive_effects enter: :slide, exit: :fade   # built-ins (shipped CSS)
  # reactive_effects update: false              # disable one hook
  # reactive_effects false                      # opt this component out entirely
  # reactive_effects enter: :random             # a random built-in per application
end

# 3. PER CALL — the escape hatch for one stream:
reply.remove(effect: :shake)                    # a dramatic one-off exit
reply.append(item, to: :items, effect: :scale)  # this row only
Item.replace(@todo, effect: false)              # suppress a declared effect once
Row.broadcast_to(@list, :todos, append: todo, target: "rows", effect: :slide)
```

The hooks map to stream actions: **enter** (`append`/`prepend`) animates the
arriving element, **exit** (`remove`) runs *before* the element leaves the DOM
(the removal waits for the animation, capped at 1s so a missing stylesheet can
never wedge it), **update** (`replace`/`update`, plain or morph) flashes the
fresh render. Effects fire for the actor's own reply AND for broadcasts alike
— if a debounced-save grid flashes too much, declare `reactive_effects
update: false` on that component.

Link the shipped stylesheet once (five built-ins — `:fade`, `:slide`,
`:scale`, `:highlight`, `:shake` — wrapped in `prefers-reduced-motion:
no-preference`, tunable via `--reactive-fx-*` CSS custom properties):

```erb
<%= stylesheet_link_tag "phlex/reactive/effects" %>
```

Custom effects skip the stylesheet entirely: pass named class legs (the same
`{ during:, from:, to: }` vocabulary `js.toggle(transition:)` uses), perfect
for Tailwind utilities:

```ruby
reactive_effects enter: { during: %w[transition-all duration-300],
                          from: %w[opacity-0 translate-y-2],
                          to: %w[opacity-100 translate-y-0] }
```

Unknown effect names raise at class load (server) and warn-and-skip on the
client (default-deny, two-sided). With effects off (the default) the wire is
byte-identical to previous releases; with them on, the resolved hooks ride the
component root as `data-reactive-effect-*` attributes — identity, never state,
and identical on Action Cable and pgbus.

### Configuration (`config/initializers/phlex_reactive.rb`)

```ruby
Phlex::Reactive.configure do |c| end if false # (plain accessors below)

# Inherit auth/CSRF/Current from your app on the action endpoint:
Phlex::Reactive.base_controller_name = "ApplicationController"

# Render your authorization library's error as 403:
Phlex::Reactive.authorization_errors = [Pundit::NotAuthorizedError]
# or: [ActionPolicy::Unauthorized]

# verify_authorized (ON by default): an action that authorizes NOTHING raises
# AuthorizationNotVerified inside the transaction (the mutation rolls back —
# fail-closed). Satisfy it by calling one of authorization_methods, calling
# mark_authorized! after a bespoke check, or declaring skip_verify_authorized on
# a genuinely public component/action. Set the method names to match your library:
Phlex::Reactive.authorization_methods = %i[authorize! authorize allowed_to?]
# Phlex::Reactive.verify_authorized = false   # turn the guard off (not recommended)

# Use your ApplicationController to render components (app helpers / Current):
Phlex::Reactive.renderer = ApplicationController

# Sign tokens with a dedicated key instead of secret_key_base:
Phlex::Reactive.verifier = ActiveSupport::MessageVerifier.new(ENV["REACTIVE_KEY"])

# Change the endpoint path (default "/reactive/actions"):
Phlex::Reactive.action_path = "/_r/actions"

# Diagnostic error bodies + dropped-param logging (default: Rails.env.local? —
# on in development AND test, off in production):
Phlex::Reactive.verbose_errors = true

# User-visible flash on endpoint failures (default nil = off). When set, every
# rescue path (400/403/404 AND a 500 crash) ALSO renders a turbo-stream flash the
# user sees — at the SAME status it returns today (statuses never change). The
# lambda receives the failure kind (:tampered/:unknown_class/:not_reactive_class/
# :forbidden/:not_found, or :error for an action-body crash), so you can map it to
# a friendly message:
Phlex::Reactive.error_flash = ->(kind) do
  case kind
  when :not_found  then "That item is no longer available."
  when :forbidden  then "You don't have permission to do that."
  else                  "Something went wrong — please try again."
  end
end

# Effects (issue #215): opt in globally + set the app-wide default hooks; see
# "Effects" above. Off (nil) by default — byte-identical wire when off.
Phlex::Reactive.effects = { enter: :fade, exit: :fade, update: :highlight }

# Turnkey APM integration. Names each action Component#action in AppSignal/Sentry/
# Datadog and reports action-body crashes with component/action tags. SDK is
# runtime-detected (no gem dependency); a custom object responding to
# record_action/record_error works too. See "Observability" above.
Phlex::Reactive.apm = :appsignal

# Report action-body crashes to any tracker yourself (the DIY escape hatch):
Phlex::Reactive.on_action_error do |error, ctx|
  Honeybadger.notify(error, context: { component: ctx[:component], action: ctx[:action] })
end

# Component-aware wrapper around every action (audit / rate-limit / assert).
# Sees the resolved component, action name, and COERCED params; runs inside
# the connection-id scope but OUTSIDE the transaction. See "Two seams" below.
Phlex::Reactive.around_action do |ctx, &action|
  RateLimiter.check!(ctx.request.remote_ip, ctx.action_name) # raise -> 403
  result = action.call
  AuditLog.record!(actor: Current.user, action: ctx.action_name)
  result # <- REQUIRED: return the continuation's value
end
```

#### Two seams: HTTP-layer (`base_controller_name`) vs component-layer (`around_action`)

There are two places to wrap a reactive action, and they see different things:

| | Base controller (`base_controller_name`) | `Phlex::Reactive.around_action` |
|---|---|---|
| **Layer** | HTTP request | the resolved component action |
| **Sees** | headers, session, `request` | the component instance, action name, **coerced** params, `request` |
| **Runs** | full Rails filter chain | inside `with_connection_id`, **outside** the transaction |
| **Use for** | auth, CSRF, coarse per-IP rate limiting | audit logging, component-aware rate limiting, assertions |

Plain Rails `around_action` / `rate_limit` on a dedicated base controller already
covers attributes, authentication, and coarse per-IP throttling — but that layer
never sees the resolved component, the declared action name, or the coerced
params, and can't sit *inside* the connection-id scope yet *outside* the action's
transaction. `Phlex::Reactive.around_action` is that component-aware seam. `ctx` is
a frozen `Phlex::Reactive::ActionContext` (`component`, `action_name`, `params`,
`request`); the fold runs *after* token verify, default-deny, and param coercion,
so a wrapper can never widen what's invokable.

**Contract — each wrapper MUST return `action.call`'s value.** The endpoint
type-checks the action's return for a `Phlex::Reactive::Response`; a wrapper that
ends on its logger's return value instead silently downgrades every reply to the
implicit self-replace. A wrapper raising a registered `authorization_errors` error
renders as 403; an unregistered raise is a 500. Multiple wrappers nest in
registration order (last-registered outermost). Tests reset the stack with
`Phlex::Reactive.reset_around_actions!`.

If you set a custom `action_path`, expose it to the client:

```erb
<meta name="phlex-reactive-action-path" content="<%= Phlex::Reactive.action_path %>">
```

The client request timeout (default 30 s) is likewise an app-authored meta —
there is no server-side setting, so drop it in your layout head if 30 s is wrong
for your slowest action:

```erb
<meta name="phlex-reactive-timeout" content="15000"> <%# 15s, in ms #%>
```

---

## Security

phlex-reactive is built so the easy path is the safe path — but the boundary is
real, so read this once.

- **State is never trusted from the client.** The DOM holds a `MessageVerifier`-
  signed identity — `{component, gid}` (record-backed), `{component, state}`
  (state-backed), or `{component, gid, state}` when a component declares both —
  not raw state. A tampered class, record, or state value fails signature
  verification → 400.
- **Actions are default-deny.** Only methods declared with `action :name` are
  invokable. A public method without `action` is unreachable.
- **You must authorize.** The signature proves the *token is yours*, not that
  *this user may act on this record*. Call your authorizer inside the action
  (`authorize! @todo, :update?`) and register its error in
  `Phlex::Reactive.authorization_errors`.
- **Params are schema-coerced.** Only declared params reach your method, each
  cast to its declared type. No raw mass assignment.
- **CSRF + auth are the host app's.** The endpoint inherits from your configured
  `base_controller_name`. Inherit `ApplicationController` to get CSRF and auth —
  but if you have *public* reactive components, ensure the action path isn't
  force-redirected to a login page for logged-out users.

### Token payload versioning

The signed identity payload carries a version (`"v"`,
`Phlex::Reactive::TOKEN_VERSION`) so a future change to the token *shape* can
**upgrade tokens already in flight** instead of breaking every open page at
deploy. When you change the shape, bump `TOKEN_VERSION` and register an upgrader:

```ruby
# config/initializers/phlex_reactive.rb
Phlex::Reactive.register_token_upgrader(0) do |payload|
  payload.merge("gid" => rewrite_old_gid(payload["gid"]))
end
```

On verify, the payload runs through the upgrader chain (oldest → current) before
your component rebuilds from it. A pre-versioning token (no `"v"`) is read as-is
— introducing versioning invalidated nothing. It **fails closed**: a token signed
by a *newer* deploy than the running code (a rollback) verifies its signature but
carries an unknown version, so `Phlex::Reactive.verify` returns `nil` and the
endpoint answers 400 — never guessing a shape it doesn't understand. See
[the security guide](https://phlex-reactive.zoolutions.llc/docs/security#token-lifetime-rotation)
for depth.

### Debugging endpoint failures (`verbose_errors`)

Every endpoint failure is warn-logged as `[phlex-reactive] …` in **every**
environment. With `Phlex::Reactive.verbose_errors` on (the default in
development and test via `Rails.env.local?`; off in production), the failure
response ALSO carries a plain-text diagnostic body — the client already prints
it via `console.error` — and param coercion warn-logs every dropped key with
its full bracketed path and reason (`undeclared` / `uncoercible`), including a
hint when a flat name looks like the bracketed twin of a declared nested key
(or vice versa). What each status means:

- **400** — token signature invalid (stale token from before a deploy?
  `secret_key_base` mismatch?), a token class that no longer resolves, or a
  class that resolved but doesn't include `Phlex::Reactive::Component`
- **403** — an undeclared action (the body lists the declared actions) or a
  registered authorization error raised inside the action
- **404** — the signed GlobalID no longer resolves (record deleted)

The flag never changes a status — only the body and the coercion log.

The same flag also makes `on(:typo)` fail loudly at **render** time: when
`verbose_errors` is on, `on(:name)` raises `Phlex::Reactive::Error` (listing the
declared actions) if `:name` isn't declared on that component — so a misspelled
or forgotten `action` surfaces the moment you load the page in dev/test, instead
of as an unexplained 403 on click. Production (flag off) keeps the permissive
emit, so a stale page after a deploy that removed an action never 500s on render.
A component that declares no actions of its own (a cross-component dispatch
helper — a child row rendering a trigger for its container's action) is skipped;
`on_client` triggers are never checked (they aren't declared actions). The
server's default-deny stays the security boundary — this is a dev-time courtesy.

The flag reaches the **client** too: reactive roots (and server-emitted
`reactive:js` streams) carry `data-reactive-verbose="true"` when it is on, and
the client op interpreter uses that gate to `console.warn` when a client op —
`on_client`, a reducer's `$ops`, `reply…js(...)`, `broadcast_js_to`, or a
busy/optimistic hint — resolves **zero targets**. The warning names the op, the
selector, and the scoping root, dedupes per unique case per page, and hints the
documented escape (`to: :root` / `global: true`) when the element exists but
was filtered out by root scoping or the nested-root ownership rule — the trap
where the element is right there in the DOM, just outside the op's scope. A
`reactive:js` stream whose `target` root id has left the DOM warns the same
way instead of silently dropping its ops. Production (flag off) renders no
attribute and stays byte-identical and silent.

See [docs/security.md](https://phlex-reactive.zoolutions.llc/docs/security) for the threat model and a checklist.

---

## How it beats Stimulus + Turbo (same feature, less code)

A counter, today vs. with phlex-reactive:

<table>
<tr><th>Stimulus + Turbo</th><th>phlex-reactive</th></tr>
<tr><td>

```js
// counter_controller.js
import { Controller } from "@hotwired/stimulus"
export default class extends Controller {
  static values = { url: String }
  increment() { this.#post("increment") }
  decrement() { this.#post("decrement") }
  #post(op) {
    fetch(`${this.urlValue}/${op}`, {
      method: "POST",
      headers: { "X-CSRF-Token": token() },
    })
  }
}
```
```erb
<%# _counter.html.erb %>
<div id="<%= dom_id(@counter) %>"
     data-controller="counter"
     data-counter-url-value="<%= counter_path(@counter) %>">
  <button data-action="counter#decrement">−</button>
  <span><%= @counter.value %></span>
  <button data-action="counter#increment">+</button>
</div>
```
```ruby
# routes + controller
resources :counters do
  member { post :increment; post :decrement }
end
def increment
  @counter.increment!(:value)
  render turbo_stream: turbo_stream.replace(
    dom_id(@counter), partial: "counter",
    locals: { counter: @counter })
end
```

</td><td>

```ruby
class Counter < ApplicationComponent
  include Phlex::Reactive::Component

  reactive_record :counter   # also defaults #id to dom_id(@counter)
  action :increment
  action :decrement

  def initialize(counter:) = @counter = counter

  def increment = @counter.increment!(:value)
  def decrement = @counter.decrement!(:value)

  def view_template
    div(**reactive_root) do
      button(**on(:decrement)) { "−" }
      span { @counter.value }
      button(**on(:increment)) { "+" }
    end
  end
end
```

*One file. No JS. No routes. No partial. No hand-picked target.*

</td></tr>
</table>

---

## Live updates with pgbus (recommended)

[pgbus](https://github.com/zoolutions/pgbus) replaces Action Cable's transport
with Postgres SSE and fixes its reliability gaps. With it installed,
`broadcast_to` and `turbo_stream_from` route over pgbus automatically:

```ruby
class Message < ApplicationRecord
  broadcasts_to ->(m) { [m.room, :messages] }, durable: true
end
```

- **Transactional**: a broadcast inside a transaction that rolls back never
  fires — *and* the DB change is undone. No "ghost" UI updates.
- **Reconnect-safe**: a tab that dropped replays missed messages on reconnect
  (`Last-Event-ID` + PGMQ archive).
- **No race on subscribe**: messages broadcast between render and subscribe are
  replayed, not lost.
- **No Redis, no Action Cable.**

See [docs/broadcasting.md](https://phlex-reactive.zoolutions.llc/docs/broadcasting) and
[docs/transport-pgbus.md](https://phlex-reactive.zoolutions.llc/docs/transport-pgbus).

---

## Observability

The hot paths emit `ActiveSupport::Notifications` events, so an APM (AppSignal,
Datadog, Skylight) sees reactive traffic at the **component level** — which
component/action a slow request was, render time, and broadcast fan-out. Three
events, all under the `phlex_reactive` namespace:

| Event | Fires | Payload |
|-------|-------|---------|
| `action.phlex_reactive` | once per request | `component`, `action`, `outcome` (`ok`/`denied_undeclared`/`invalid_token`/`not_found`/`unauthorized`/`unverified`) |
| `render.phlex_reactive` | per component render | `component`, `bytesize` |
| `broadcast.phlex_reactive` | per `broadcast_to` call (Action Cable **and** pgbus) | `component`, `stream_action`, `streamables` |
| `defer.phlex_reactive` | once per deferred render (the `reply.defer` pull/push endpoint) | `component`, `outcome` (`ok`/`no_content`/`invalid_token`/`not_found`/`unauthorized`) |

Payloads carry **names, the outcome, and sizes only** — never the token, params,
or state, so an event can't leak a secret. Subscribe from an initializer:

```ruby
ActiveSupport::Notifications.subscribe("action.phlex_reactive") do |*args|
  event = ActiveSupport::Notifications::Event.new(*args)
  MyAPM.record("reactive.#{event.payload[:outcome]}", event.duration,
    component: event.payload[:component], action: event.payload[:action])
end
```

To watch reactive traffic in your own log without an APM, flip on the bundled
`LogSubscriber` (default off) — one compact line per event at DEBUG:

```ruby
# config/initializers/phlex_reactive.rb
Phlex::Reactive.log_events = true
# [reactive] Counter#increment ok (3.1ms)
# [reactive] render Counter 512B (0.9ms)
# [reactive] broadcast replace Counter →2 (1.4ms)
```

The events fire whether or not you enable the LogSubscriber; the flag only
controls the gem's own log lines. See
[docs/performance.md](https://phlex-reactive.zoolutions.llc/docs/performance).

### Turnkey APM adapters (AppSignal, Sentry, Datadog)

Subscribing by hand is the DIY path. For the common trackers there's a one-liner
that both names the transaction and reports errors — so reactive traffic stops
rolling into one blurry `ActionsController#create` and a crash arrives at your
tracker with context:

```ruby
# config/initializers/phlex_reactive.rb
Phlex::Reactive.apm = :appsignal   # or :sentry, :datadog, or a custom object
```

With it set:

- Each reactive action shows in the APM as its OWN transaction/span —
  `Counter#increment`, not `Phlex::Reactive::ActionsController#create` — tagged
  with the component, action, and outcome.
- An action body that raises a genuine error (a 500, not a registered 4xx) is
  **reported to the tracker with `component`/`action` tags**, then re-raised
  unchanged so Rails' own error reporting still fires.

The SDK is **runtime-detected** — no gem dependency is added. If the named SDK
isn't loaded, `apm =` logs one warning at boot and no-ops (the same optionality
invariant as pgbus). A custom object works too — anything responding to
`record_action(payload, duration_ms)` and `record_error(error, payload)`.

For a tracker with no built-in adapter, report errors yourself — this hook fires
on any previously-uncaught action-body error, with the name-only context:

```ruby
Phlex::Reactive.on_action_error do |error, ctx|
  Honeybadger.notify(error, context: { component: ctx[:component], action: ctx[:action] })
end
```

And to show the user a flash when an action crashes (the SAME hook the 4xx errors
already use — `kind` is `:error` for a crash):

```ruby
Phlex::Reactive.error_flash = ->(kind) { "Something went wrong — please retry." }
```

See [docs/observability.md](https://phlex-reactive.zoolutions.llc/docs/observability).

### Client debug mode (devtools-lite)

The `LogSubscriber` above is the **server** lens. The client lens is
`console.error` on a failure plus the [lifecycle events](#failure-ux--lifecycle-events)
— but on the *successful-but-wrong* path (which streams arrived? did a token
refresh come?) there was nothing to see. `Phlex::Reactive.debug` fills that gap:

```ruby
# config/initializers/phlex_reactive.rb
Phlex::Reactive.debug = Rails.env.development?
```

With it on, every reactive root carries `data-reactive-debug="true"` and the
generic controller `console.group`s **every dispatch** in the browser:

```text
▼ reactive #todo_42 rename → 200 (48ms)
    params: [title] + collected: [title]
    encoding: json
    streams: replace → #todo_42
    token: refreshed ✓
```

The trace carries **names and outcomes only** — the explicit param names and the
collected sibling-field names (never their **values**, which may be sensitive),
the request encoding (`json`/`multipart`), the HTTP status, the response's stream
actions + targets, whether a token refresh arrived (**never the token value**),
and the round-trip time. Off (the default) it does nothing — a single attribute
check per dispatch, no string building — so it is safe to leave gated on
`Rails.env.development?`.

---

## Testing

`Phlex::Reactive::TestHelpers` is the public test surface — mix it in once and
never reach for a private method or a hand-rolled POST:

```ruby
# spec/rails_helper.rb
RSpec.configure do |c|
  c.include Phlex::Reactive::TestHelpers                  # run_reactive + matchers
  c.include Phlex::Reactive::TestHelpers, type: :request  # + the HTTP helpers
end
```

**`run_reactive` — the no-HTTP action driver.** It runs the action through the
SAME contract the endpoint enforces — default-deny, the signed identity
round-trip (a record-backed component's row is re-found), schema coercion, the
transaction wrapper — with no HTTP, and returns a `Result`. So a unit test can't
pass on a component that would fail a real click:

```ruby
result = run_reactive(Counter.new(count: 0), :set, count: "42")  # client sends strings
expect(result).to have_reactive_replace("counter")
expect(result.component.instance_variable_get(:@count)).to eq(42)  # :integer, cast

# default-deny, deleted-record, and authorization all surface as the real failures:
expect { run_reactive(Counter.new(count: 0), :drop_table) }
  .to raise_error(Phlex::Reactive::TestHelpers::UndeclaredReactiveAction)
```

`Result` answers `replace?` / `remove?` / `redirect?` / `redirect_url` /
`streams` / `response`, plus `component` (the instance rebuilt from identity, the
one the action ran against). A registered authorization error **raises** (the
endpoint maps it to 403). Matchers: `have_reactive_replace`,
`have_reactive_remove`, `have_reactive_token_for` — the last pins the token
refresh so a reply that would silently break the next click fails your test.

**HTTP helpers** — `post_reactive_action(component_or_class, act, params:, payload:)`
and `post_reactive_multipart(...)` POST a signed token to
`Phlex::Reactive.action_path` exactly as the client does. **Token minting** —
`reactive_token_for(component_or_class, payload = {})`.

> `verbose_errors` defaults ON in test (it changes only an error BODY, never a
> status). Asserting an empty failure body? Set
> `Phlex::Reactive.verbose_errors = false` in your setup.

See [the testing guide](https://phlex-reactive.zoolutions.llc/docs/testing) for
the full layer-by-layer walkthrough.

---

## Documentation

- [Installation & bundler setups](https://phlex-reactive.zoolutions.llc/docs/installation)
- [Mental model & architecture](https://phlex-reactive.zoolutions.llc/docs/architecture)
- [Actions & events (the `on(...)` API)](https://phlex-reactive.zoolutions.llc/docs/actions-events)
- [Security & threat model](https://phlex-reactive.zoolutions.llc/docs/security)
- [Broadcasting & live updates](https://phlex-reactive.zoolutions.llc/docs/broadcasting)
- [Transport: pgbus vs Action Cable](https://phlex-reactive.zoolutions.llc/docs/transport-pgbus)
- [Testing reactive components](https://phlex-reactive.zoolutions.llc/docs/testing)
- [Performance & benchmarking](https://phlex-reactive.zoolutions.llc/docs/performance)
- Examples: [counter](https://phlex-reactive.zoolutions.llc/docs/example-counter) ·
  [payment split](https://phlex-reactive.zoolutions.llc/docs/example-payment-split) ·
  [chat](https://phlex-reactive.zoolutions.llc/docs/example-chat) · [todo list](https://phlex-reactive.zoolutions.llc/docs/example-todo-list) ·
  [inline edit](https://phlex-reactive.zoolutions.llc/docs/example-inline-edit) ·
  [notifications](https://phlex-reactive.zoolutions.llc/docs/example-notifications) ·
  [collections](https://phlex-reactive.zoolutions.llc/docs/example-collections) ·
  [file uploads & custom types](https://phlex-reactive.zoolutions.llc/docs/example-uploads) ·
  [loading states](https://phlex-reactive.zoolutions.llc/docs/example-loading-states) ·
  [client-only ops](https://phlex-reactive.zoolutions.llc/docs/example-client-ops) ·
  [failure surface](https://phlex-reactive.zoolutions.llc/docs/example-failure) ·
  [team inbox](https://phlex-reactive.zoolutions.llc/docs/example-team-inbox)

## Credits & prior art

The mental model is stolen, gratefully, from
[Laravel Livewire](https://livewire.laravel.com) (public method = action) and
[Phoenix LiveView](https://www.phoenixframework.org) (a component is a re-render
unit). The transport and reliability come from
[pgbus](https://github.com/zoolutions/pgbus). The rendering is all
[Phlex](https://www.phlex.fun).

## License

[MIT](LICENSE.txt).
