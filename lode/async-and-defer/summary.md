# Async: deferred renders and the settle lifecycle

`lib/phlex/reactive/defer.rb`, `deferred_render_job.rb`, `pending.rb`, `settle.rb`, `settles.rb`, plus `component/lazy.rb` and the endpoint's `#deferred`.

Two features, one transport story. **Defer** takes a RENDER off the actor's critical path. **Settle** takes the OUTCOME of work the action merely enqueued and delivers it when the job knows it.

## Why a settle exists

The endpoint runs an action inside a transaction and renders the reply THERE, while a queue adapter publishes on COMMIT. So any `reply.morph` after an enqueue renders from a database the job has not touched yet, and is guaranteed to draw the pre-job world — rows still present, buttons still live — next to the "Queued 177 transfers" flash the same reply emitted. `reply.pending` replies truthfully instead.

## Delivery lanes

| Lane | How | Availability |
|---|---|---|
| **pull** (`:fetch`) | the directive carries a purpose-scoped, short-TTL defer token; the client POSTs it to `/reactive/defer` off the action queue | always — it is just HTTP |
| **push** (`:stream`) | a pgbus durable one-shot stream plus `DeferredRenderJob`; the reply carries a signed SSE src and `since-id="0"` | `defer_push_capable?` |

`Defer.resolve_via` is evaluated per reply: `:fetch` forces pull; `:stream` requests push but degrades to pull with a once-per-process warning when the capability is absent; `:auto` picks push iff capable. `since-id="0"` on a FRESH key is what closes the broadcast-before-subscribe race — pgbus's connect-time read_after replays the job's durable broadcast even when the job beat the subscription, which is also why `durable: true` is load-bearing and why the one-shot queue is left to pgbus's orphan sweep rather than dropped eagerly.

**A settle has no pull lane at all.** The client cannot poll "is the job done yet", and redeeming such a token at the defer endpoint would render the PRE-JOB component — the exact bug `reply.pending` exists to fix. So `settle_capable?` requires the push lane, and the pending directive deliberately carries NO `data-reactive-defer-token` (that attribute is the client's degrade-to-fetch path).

## `reply.defer`

`Response#defer` records a `Defer::Segment(component, placeholder, morph)`; the ENDPOINT turns it into wire streams after the transaction committed. `validate_segment!` fails loudly at the call site for a non-reactive component (its identity could never be rebuilt) or a bogus placeholder type, and `Response#defer` refuses a redirect reply outright (the client is navigating away).

`streams_for` emits the optional placeholder shell FIRST — so the pending state paints before delivery starts — then the directive. The shell is a `<div>` that OWNS the component's id (it is the stream target) carrying `data-reactive-defer-pending`, `aria-busy` and `.reactive-defer-placeholder`, and deliberately NO defer token: the directive owns delivery, and a token on the shell would double-fetch through the lazy-mount connect probe. `placeholder:` is nil (keep current content), `true` (the component's `deferred_placeholder`, else an empty shell), a String, or a Phlex component — resolved through the same escape contract as flash and `also`.

Bare `reply.defer(component)` builds on `Response.build_streams(@component)`, i.e. a token-ONLY refresh rather than a full self-replace: a full replace would render the acting component synchronously, and `reply.defer(self)` would then be silently defeated by a double render.

`one_shot_stream_key` sizes its random hex suffix to pgbus's LIVE queue-name budget (preferring pgbus's own `Key.queue_name_budget`, then `47 − prefix − 1`, then the documented default), because a fixed-width key would raise `StreamNameTooLong` in the JOB — after the directive already shipped, leaving the shimmer hanging forever. The suffix is hex and never contains hyphens: pgbus's sanitizer strips them, which would collide two keys differing only by a hyphen. When the budget cannot fit `DEFER_KEY_MARKER` plus the 16-char collision-safe minimum it RAISES, and `push_directive_attrs`' rescue degrades the segment to `:fetch`.

`push_directive_attrs` runs AFTER the action committed, so a signing or enqueue failure must not 500 a reply whose mutation already persisted — it warns and falls back to the fetch directive. It also ships a fallback defer token ALONGSIDE the stream src: the server picks push on SERVER-side capability alone, but the browser may not have the pgbus client loaded.

## `DeferredRenderJob`

Rebuilds the component from its identity payload off the request thread, renders, and broadcasts durably to the one-shot key. Every payload ends with a remove of the client's `<pgbus-stream-source>` by its deterministic id (`reactive-defer-src-<target>`), whose `disconnectedCallback` closes the SSE — so the subscription tears itself down with the content it delivered, and there is no client-side arrival bookkeeping.

A non-reactive class raises OUTSIDE the render rescue (a bad enqueue is a programming error and must broadcast nothing). Everything else — a record deleted while queued, `render? == false`, a render that raises — broadcasts the CLEANUP instead (pending-clear ops + teardown): the stream lane has no client-side timeout, so a silent job death would hang the shimmer forever. If the cleanup broadcast itself succeeds the original error is swallowed (a retry would raise identically) and logged unless it was a `RecordNotFound`; if the cleanup broadcast fails, that propagates so the retry policy gets a chance.

## `reply.pending` → `Pending`

`build_segment` does three things in order: materialize `records` ONCE, mint one handle, run the caller's enqueue with the handle installed in a thread-local, and record a `Segment`.

**One key per call is a hard design rule.** A durable pgbus broadcast to a never-seen key creates a real PGMQ queue reclaimed only by an hourly orphan sweep at a 24h threshold — a key per record would leave 177 tables for a day and open 177 SSE connections. So all N settles of one call share ONE key and ONE subscription, anchored on the container's id. Because the key is shared, teardown must be explicit (`reactive_settle(finish:)`), not per-arrival.

`Handle` carries `stream_key`, `container_class`, `container_payload`, `anchor`, `collection`, `target_ids`, `peers`, `connection_id`, and round-trips through plain JSON (`to_h_wire` / `from_wire`) because it rides ActiveJob metadata. `resolve_targets` maps records through the collection declaration when `in:` is given; without it every entry must already be a Streamable component. `resolve_peers` turns `peers: true` into the container's own record (GlobalID-serialized so it survives the trip into the job) and refuses a state-backed container, which has no record stream.

`run_enqueue`: an explicit block wins, else the `job:`/`args:` sugar. The sugar enqueues ONE job PER RECORD with the handle NARROWED to that record's target id — which is what makes a failure attributable. The block form cannot be narrowed (the gem cannot map an arbitrary `perform_later` back to a record), so it carries the whole target list. An Array `args:` for more than one record raises as ambiguous.

`streams_for` emits, in apply order: one `reactive:js` pending marker per target (setting `data-reactive-pending` and `aria-busy` through the existing op lane, so the client needed no change), the same marker on the anchor, then the single subscription directive.

Without the push lane `build_segment` warns once, still runs the enqueue, and returns nil — no handle (so `reactive_settle` no-ops exactly like a sweep-enqueued job) and no pending markers. Today's behaviour, never a shimmer that could never resolve.

## `Settles` and `Settle` — the job side

`include Phlex::Reactive::Settles` in the job. `#serialize` copies the ambient handle into the job's metadata and `#deserialize` restores it, so **`perform`'s arity is untouched** and every OTHER caller of the same job — a nightly sweep, a webhook — enqueues it with no handle, in which case `reactive_settle` is a no-op returning nil. (`perform_now` skips serialize/deserialize and so carries no handle either, which is the correct reading: a synchronous call has no pending UI waiting on it.)

`Settle` is a MUTABLE accumulator (a settle block is imperative), not a value object; every verb returns self. `replace`, `remove`, `append`, `prepend`, `move` (ordered remove-then-append so a row is never momentarily in both containers), `count`, `flash`, `js`, `streams!`. `from:`/`to:` default to the collection `reply.pending` named; a settle with neither raises. Every collection verb routes through the SAME `Collections` decisions the reply path uses — that shared bookkeeping is the whole point.

`deliver_settle` joins every stream into ONE durable message (the row, the count and the empty-state belong to the same instant, which is also why the ACTOR path needs no coalescing), appends the finish streams when `finish_settle?`, and then delivers peers. `finish: :auto` finishes only when the call marked exactly one target; a fan-out passes `finish: true` from whatever knows it is last.

If the block raises, the target's pending markers are still cleared (the shimmer must not lie) and the error is RE-RAISED so the retry policy sees it; the subscription is deliberately NOT torn down, because a retry must still reach the actor.

Related: `../streaming/summary.md`, `../review/async-actions.md` (the attribution, peer and key rules, each with its proving spec).
