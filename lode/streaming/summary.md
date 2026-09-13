# Streaming: Streamable and Collections

`lib/phlex/reactive/streamable.rb` (859 lines) and `lib/phlex/reactive/collections.rb`.

## `#id` — the one contract

Every streamable component must return a stable DOM id from `#id`, and the root element in `view_template` must carry it: that id IS the Turbo Stream target, which is why targets are never hand-picked. A record-backed component (`reactive_record :x`) gets `dom_id(record)` for free; everything else raises `NotImplementedError` with the fix in the message, because a class-name default would collide the moment two instances render on one page. Two DIFFERENT component classes rendering the SAME record on one page also collide on the default — one of them needs a prefixed id.

`Streamable#dom_id` delegates to `ActionView::RecordIdentifier`, NOT Phlex's render-time helper: the machinery calls `#id` BEFORE rendering, so Phlex's `dom_id` would raise `HelpersCalledBeforeRenderError`.

## Rendering

`render_component(component)` uses phlex-rails' `#render_in` against a memoized off-request view context — a direct `component.call` that skips `ActionController::Renderer`'s `TemplateRenderer`/`LookupContext`/log-subscriber machinery: roughly 2× faster with about half the allocations, byte-identical HTML, full helper access. It wraps the render in the `render.phlex_reactive` event (component name + html bytesize, filled after rendering) and inside `Defer.with_real_render` so a `reactive_lazy` component emits its real template.

The view context and its `Turbo::Streams::TagBuilder` are cached PER THREAD (`ThreadViewContext`), keyed on the renderer object's identity and a per-class generation. Per-thread and not per-process because an ActionView context carries mutable `output_buffer`/`view_flow` state that `render_in`'s capture swaps — one shared instance can interleave content on Puma or in concurrent jobs. `reset_turbo_view_context!` bumps the generation; `Streamable.reset_all_view_contexts!` walks a `WeakMap`-backed registry of every includer and is called from the engine's `to_prepare`. The registry is a `WeakMap` used as a set so a Zeitwerk-reloaded class is GC'd instead of pinned.

**The gem deliberately does NOT include `Turbo::Streams::ActionHelper`** — it pulls in `ActionView::Helpers::TagHelper`, which overrides Phlex's internal `tag` method and breaks rendering. `Turbo::Streams::TagBuilder` is used directly.

## Stream builders

Class-level, each returning a wrapped `Stream`:

| Builder | Target | `renders_root` |
|---|---|---|
| `replace(model, morph:, effect:)` | the built component's `#id` | true |
| `update(model, morph:, effect:)` | the built component's `#id` | true |
| `append(target:, model:, effect:)` | the caller's container id | **false** — it inserts a CHILD, and a reactive child's own token is not the container's |
| `prepend(target:, model:, effect:)` | the caller's container id | false |
| `remove(model, effect:)` | the built component's `#id` | false |

Instance-level: `to_stream_replace(morph:, effect:)`, `to_stream_update(morph:, effect:)`, `to_stream_remove(effect:)`, and `to_stream_token` — a body-less `<turbo-stream action="reactive:token">` carrying just the fresh signed token, so a partial reply rolls the identity forward without tearing down a live input. `to_stream_token` reads the token through `respond_to?(:reactive_token, true)` **with the include-private flag**: `reactive_token` is private, so a plain `respond_to?` is false for every Component and the stream would silently carry an EMPTY token — which makes any non-self-rendering reply act-once-only.

`morph: true` emits `method="morph"` so Turbo 8's bundled Idiomorph morphs in place and a focused input keeps its caret; the default is the plain outerHTML swap and is byte-identical to the pre-morph wire. `to_stream_morph` is removed and raises with the `to_stream_replace(morph: true)` rewrite.

## `broadcast_to` — one method, one verb kwarg

```ruby
Item.broadcast_to(@list, :todos, replace: @todo, morph: true)
Item.broadcast_to(@list, :todos, append: todo, target: dom_id(@list, :todos), exclude: reactive_connection_id)
Counter.broadcast_to(each: accounts.map { [it, :counters] }, replace: counter)
Badge.broadcast_to(user, :alerts, js: js.add_class("#bell", "has-unread"))
Phlex::Reactive.broadcast_to(@list, :todos, update: TodoCount.new(list: @list), target: "todos-count")
```

Exactly ONE of the six verbs (`replace`, `update`, `append`, `prepend`, `remove`, `js`); zero or two raise. `replace`/`remove` are SELF-TARGETING — they derive the target from the payload's `#id` and require a Streamable payload, with a guided error steering a plain component to `update:`. `update` self-targets too when no `target:` is given; `append`/`prepend` require an explicit `target:`. The payload is a record (built via `model_param_name`), an init-kwargs Hash (used verbatim — no `**options` collision), or an already-built Phlex component. `each:` fans ONE build + ONE render + ONE signing out to K keys with K cheap channel calls.

Both the class-level form and the module-level `Phlex::Reactive.broadcast_to` funnel through `Streamable.broadcast_component`, so neither can be silently un-instrumented and the actor-only op gate is reachable from both doors. `broadcast_raw` is the same path for already-rendered HTML (the count companion is a plain number with no render leg).

`exclude:`, `visible_to:` and `coalesce:` are TRANSPORT options, not init args, and they do **not** travel as kwargs to `Turbo::StreamsChannel` — turbo-rails swallows unknown kwargs into its render locals, so passing `exclude:` that way silently dropped the actor-echo suppression. They ride thread-locals (`Thread.current[:pgbus_broadcast_exclude]` and siblings) that pgbus's `broadcast_stream_to` patch reads, set by `with_pgbus_broadcast_opts` under the `pgbus_streams?` gate and cleared in `ensure`. On Action Cable nothing reads them, so the whole thing is a no-op. `coalesce:` needs a newer pgbus still; an older one simply ignores the thread-local (more messages, same correctness), which is why it has no gate of its own.

`morph:` and `effect:` reach the broadcast wire through `attributes:` (the broadcast path has no `method:` kwarg), compiled by `broadcast_wire` — `{}` when neither, so a plain call is byte-identical.

A broadcast render runs inside `with_url_options(nil)`: subscribers can be on different hosts, so absolute URLs in broadcast-rendered components keep the process defaults.

`js:` broadcasts go through `broadcast_js_ops_json`, which refuses the six `BROADCAST_REFUSED_OPS` (`focus`, `focus_first`, `submit`, `paste_into`, `persist_state`, `persist_clear`) — broadcasting focus steals it in every tab, `submit` force-submits every subscriber's form, `paste_into` reads every subscriber's clipboard. That gate lives on the module singleton so BOTH doors reach it.

The eleven `broadcast_*_to` / `_to_each` methods are removed; each is defined as a stub raising with the exact `broadcast_to` rewrite for that verb.

## `Collections` — the shared bookkeeping

A collection row is never just a row: adding one must also refresh the `count:` companion and clear the `empty:` state at the 0→1 boundary; removing one must refresh the count and restore the empty state at 1→0. `Collections` holds the two DECISIONS three callers share — `Response.build_collection_*` (the actor's reply), `Settle` (the job-side settle) and `Streamable.broadcast_collection_to` (the peers' broadcast):

- `count_refresh(definition, container, size)` → `[count_target, size.to_s]` or nil (nil when no `count:` is declared or the resolver returned nil — the count stream is simply omitted, so a list with only rows still works).
- `empty_toggle(definition, container, delta, size)` → `:clear` (add, size just became 1), `:restore` (remove, size is now 0) or nil. Edge-triggered off the LIVE size, never a client-side increment.

The reply/settle paths build `<turbo-stream>` STRINGS and the broadcast path hands pieces to `Turbo::StreamsChannel`, so they cannot share the rendering — the decisions are what they share, because the decisions are what drifts. `size_of` resolves the size ONCE per delta and every renderer passes the same value down; `:__unresolved` is the not-computed-yet sentinel, distinct from a legitimately nil size.

`row_remove_stream` and `Pending.row_dom_id` both accept an already-built dom-id STRING as well as a record. `replace_streams` emits only the row — a replace moves no boundary, so no count and no empty-state stream.

`broadcast_collection_to(*keys, container:, in:, append:|prepend:|remove:, row:, coalesce:, exclude:)` is the peers' counterpart of `reply.append`/`reply.remove`: the plain `broadcast_to(append:)` emits the BARE row because it has no container instance to resolve the declaration or run the size resolver. `in:` cannot be a named parameter (it is a Ruby keyword), so it is pulled out of `**opts`. The ROW stream is never coalesced (an append is not idempotent and each row is a distinct target); the aggregate streams are.

Related: `../async-and-defer/summary.md` (the settle that reuses these decisions), `../review/async-actions.md`.
