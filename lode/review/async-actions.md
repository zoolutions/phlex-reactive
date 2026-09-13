# Review rules: the settle lifecycle (`reply.pending` → `reactive_settle`)

How a pending marker, a handle and a peer broadcast are allowed to behave. Nearly all of these came out of one PR's review; they are the rules that keep a shimmer from lying.

### A settle has no pull lane, so there is no `settle_token_ttl` to govern one
- **Holds because:** the client cannot poll "is the job done yet", and a pull token redeemed at `/reactive/defer` would render the PRE-JOB component — the exact bug `reply.pending` exists to fix. A TTL setting with nothing to govern tells an app it can extend a wait window it cannot extend. The absence is recorded in place: `lib/phlex/reactive.rb:717` carries a `NOTE: there is deliberately NO settle_token_ttl`, and the README, the docs page and the CHANGELOG each say why it is absent rather than staying silent. It may only come back alongside a real pull-token lane it governs.
- **Where:** `lib/phlex/reactive.rb` (the NOTE above `settle_coalesce_window_ms`); `Phlex::Reactive.settle_capable?`
- **Proven by:** `spec/phlex/reactive/settle_config_spec.rb:"exposes no settle_token_ttl — a settle has no pull lane for a token to govern"`
- **Origin:** cubic learning 6bc297de; PR #250

### `records` is walked into an Array exactly once before anything reads it
- **Holds because:** `reply.pending` resolves target ids and then runs the caller's enqueue from the same argument. A one-shot `Enumerator` is exhausted by the first read, so the jobs were silently never enqueued; a re-enumerable `ActiveRecord::Relation` was queried twice, so a concurrent write between the walks could mark one set of rows pending and enqueue jobs for a different set. `Pending.materialize` does the walk (`records.is_a?(Enumerable) && !records.is_a?(String) ? records.to_a : [records]`) and raises on an empty list; `resolve_targets` and `run_enqueue` both take the already-walked Array.
- **Where:** `lib/phlex/reactive/pending.rb#materialize`, called from `#build_segment`
- **Safe direction:** materializing a Relation that was already an Array costs one allocation; not materializing costs a silently unenqueued job.
- **Proven by:** `spec/phlex/reactive/pending_spec.rb:"walks a one-shot Enumerable ONCE — the targets and the enqueue share it"`, `:"resolves a Relation once, so the marked rows and the enqueued jobs cannot disagree"`
- **Origin:** PR #250

### A misspelled `reply.pending` keyword raises; it is never swallowed into `**opts`
- **Holds because:** `in` is a Ruby keyword and cannot be a named parameter, which forces every other keyword into `**opts` where a typo like `jbo:` would vanish. The result is rows marked pending with nothing enqueued to settle them — a permanently shimmering row, which is the failure this whole feature exists to prevent. `Response.pending_collection!` deletes `:in` and raises naming the leftover keys and the four legal ones; both `Reply#pending` and the chained `Response#pending` go through it.
- **Where:** `lib/phlex/reactive/response.rb#pending_collection!`, called from `Response#pending` and `Reply#pending`
- **Proven by:** `spec/phlex/reactive/pending_spec.rb:"refuses an unknown keyword rather than silently dropping it"`
- **Origin:** PR #250

### A second `reply.pending` for the same container anchor is rejected, not merged
- **Holds because:** every pending segment on one container emits a directive targeting that container's id, and the client keys its in-flight subscriptions BY TARGET — the second directive supersedes the first and silently orphans the jobs the first call enqueued. Merging looked friendlier but does not survive contact: two calls can name different collections and different `peers:`, and `Settle` resolves its default collection from `handle.collection`, so a merge would silently drop one call's default. `Response#pending` raises when `@pending_segments.any? { it.handle.anchor == subject.id }`, naming the rewrite. A **different** anchor is fine — one subscription per anchor, not one per reply.
- **Where:** `lib/phlex/reactive/response.rb#pending` (the anchor guard)
- **Proven by:** `spec/phlex/reactive/pending_spec.rb:"refuses a SECOND pending on the same container — the client would supersede the first"`
- **Origin:** cubic learning d4e51dca; PR #250

### Pending markers are cleared on both the success and the failure path, and the failure path clears only what it can attribute
- **Holds because:** the shimmer must resolve even when the work blew up, but clearing every target on one job's failure would un-dim rows that are still legitimately working. `Handle` carries `target_ids`; `finish_streams` clears `handle.target_ids + [handle.anchor]` and tears the source down. On failure, `reactive_settle` rescues, broadcasts `broadcast_settle_cleanup` and **re-raises** so ActiveJob's retry policy still sees the error — and deliberately does NOT tear the subscription down, because a retry still has to reach the actor. Attribution comes from `run_enqueue`: the `job:`/`args:` sugar enqueues one job per record through `each_with_narrowed_handle`, narrowing that job's handle to that record's target id. The **block form cannot be narrowed** — the gem cannot map an arbitrary `perform_later` back to a record — so it carries the whole target list; `finish: true` sweeps those up.
- **Where:** `lib/phlex/reactive/settles.rb#reactive_settle` (the rescue), `#finish_streams`; `lib/phlex/reactive/pending.rb#run_enqueue`, `#each_with_narrowed_handle`
- **Proven by:** `spec/phlex/reactive/settles_spec.rb:"clears the TARGET's pending markers (not just the container's) and re-raises"`, `:"clears nothing for an UNATTRIBUTABLE fan-out failure, rather than un-dimming 176 live rows"`, `:"does NOT tear the subscription down on failure — a retry must still reach the actor"`, `:"clears the pending markers off every TARGET, not just the container"`; `spec/phlex/reactive/pending_spec.rb:"narrows the handle to ONE target per job, so a failure can be attributed"`, `:"gives the BLOCK form the whole target list — an arbitrary enqueue cannot be mapped back"`
- **Origin:** cubic learning 1bd58b61; PR #250

### Peer delivery is best effort: it rescues, logs and returns — it never fails the job
- **Holds because:** by the time `deliver_peers` runs the actor's durable message is already on the wire. Re-raising hands the job to the retry policy, which re-runs `perform` and sends the actor's settle a SECOND time — duplicating exactly the pieces that are not idempotent (the flash, the empty-state append). A peer missing a cross-tab courtesy is much smaller than an actor seeing the flash twice, and every other broadcast in the gem is already best effort. `deliver_peers` ends in `rescue ::StandardError => e; log_peer_failure(e)`, which logs why the job was NOT failed.
- **Where:** `lib/phlex/reactive/settles.rb#deliver_peers`
- **Safe direction:** losing a peer's courtesy update, never re-sending the actor's settle.
- **Proven by:** `spec/phlex/reactive/settles_spec.rb:"never fails the job when a peer broadcast blows up — the actor settle already landed"`
- **Origin:** cubic learning 7e297305; PR #250

### `Settle#replace` records a peer replace and rides the ordinary row broadcast — no count, no empty-state
- **Holds because:** without a peer op a failed re-execution goes back to actionable for the actor while every other operator keeps the stale row. But a replace moves no collection boundary, so it must NOT go through `broadcast_collection_to`, which would emit a count companion and an empty-state toggle for a size that did not change. `deliver_peer_op` branches on `action == :replace` and calls `definition.item.broadcast_to(*keys, replace: definition.item.send(:build, model, row_kwargs || {}), exclude: handle.connection_id)`. A built component records a `nil` collection name and is broadcast as itself, since it self-targets.
- **Where:** `lib/phlex/reactive/settle.rb#replace`; `lib/phlex/reactive/settles.rb#deliver_peer_op`
- **Proven by:** `spec/phlex/reactive/settles_spec.rb:"reaches peers on a REPLACE too — otherwise other operators keep the stale row"`, `:"re-renders the row in place with no count churn (a replace moves no boundary)"`
- **Origin:** cubic learning 94f127d5; PR #250

### The row kwargs a settle was given travel to the peer row build
- **Holds because:** a row component with a required keyword beyond the model renders fine for the actor and **raises** on the peer path — an asymmetry that is nasty to debug, and at best peers render different markup. `Settle`'s `peer_ops` entries carry the row kwargs as their fourth element, `broadcast_collection_to` takes a `row:` keyword, and it threads into `definition.item.build(model, row)`.
- **Where:** `lib/phlex/reactive/settle.rb` (`peer_ops` entries), `lib/phlex/reactive/streamable.rb#broadcast_collection_to`, `#broadcast_collection_row`
- **Proven by:** `spec/phlex/reactive/settles_spec.rb:"carries the row kwargs to peers — a required kwarg would otherwise raise there"`
- **Origin:** cubic learning 63a6014d; PR #250

### A DOM-id String is a remove target everywhere a record is, including the peer path
- **Holds because:** `reply.remove(id, from:)` and `Settle#remove` both accept an already-built dom id, matching `Collections.row_remove_stream` — and with `peers: true` that String went straight into `definition.item.build`, which fails before the aggregate streams are emitted. `broadcast_collection_row` short-circuits a String model to `Streamable.broadcast_raw(definition.item, :remove, model, nil, keys, exclude:, visible_to:)` so it never reaches `build`. The bug is reachable from two directions — the direct `broadcast_collection_to` call and the settle — which is why the regression spec drives it from the settle side.
- **Where:** `lib/phlex/reactive/streamable.rb#broadcast_collection_row` (the `action == :remove` branch)
- **Proven by:** `spec/phlex/reactive/settles_spec.rb:"handles a dom-id STRING remove on the peer path without building a row from it"`
- **Origin:** PR #250

Related: [`../async-and-defer/summary.md`](../async-and-defer/summary.md), [`collections.md`](collections.md).
