# Review rules: collection bookkeeping

`Collections` exists because three callers — the actor's reply, the job-side settle and the peers' broadcast — must make the SAME two decisions about a row delta. These are the rules that keep those decisions from drifting or from disagreeing with each other inside one delta.

### The size resolver runs ONCE per delta and the same value reaches every decision that reads it
- **Holds because:** the `size:` resolver is usually a DB count. Evaluating it separately for the count companion and for the empty-state boundary costs an extra query on every add and remove — and, worse, a concurrent write landing between the two reads ships a count companion that contradicts the empty-state toggle beside it in the same payload. `Collections.size_of(definition, container)` is the single resolver call; `count_refresh` and `empty_toggle` both take `size = :__unresolved` and resolve only when the caller did not, so every real caller resolves first and passes the value into both. `:__unresolved` is a sentinel distinct from a legitimately nil size, which means "no count stream", not "not computed yet".
- **Where:** `lib/phlex/reactive/collections.rb#size_of`, `#count_refresh`, `#empty_toggle`, `#add_streams`, `#remove_streams`; `lib/phlex/reactive/streamable.rb#broadcast_collection_aggregates`
- **Trap in the same shape:** destructuring `target, size = count_refresh(...)` rebinds `size` to the count's **String** form; the broadcast path had exactly this and handed a String to `empty_toggle`. Name the destructured locals apart from the resolved size.
- **Proven by:** `spec/phlex/reactive/collections_module_spec.rb:"evaluates the size resolver exactly once for an add"`, `:"evaluates the size resolver exactly once for a remove"`, `:"passes the SAME size to the count companion and the empty-state boundary"`
- **Origin:** cubic learning from PR #250 (pre-existing in `collection_add_streams`, fixed in the PR that refactored it)

### The empty-state toggle is edge-triggered off the live size, never off a client-side increment
- **Holds because:** `empty_toggle` returns `:clear` only when an ADD brought the size to exactly 1 and `:restore` only when a REMOVE brought it to 0. Any other delta leaves the empty state alone, so a list that was already populated does not churn and a list that still has rows does not flash its empty state. Deriving the boundary from a counter the client keeps would drift the moment a broadcast, a settle and a reply all touched the same list.
- **Where:** `lib/phlex/reactive/collections.rb#empty_toggle`
- **Proven by:** `spec/phlex/reactive/collections_module_spec.rb:"leaves the empty-state alone when the list was already populated"`, `spec/phlex/reactive/collection_streams_spec.rb:"does NOT touch the empty-state when the list was already non-empty (size > 1)"`, `:"does NOT restore the empty-state while rows remain (size > 0)"`
- **Origin:** read off `Collections` while verifying the size-resolver rule above (PR #250's subject)

### A replace emits only the row — no count, no empty state
- **Holds because:** a replace moves no boundary. `replace_streams` emits the row stream alone, and the same reasoning routes `Settle#replace`'s peer op through the ordinary row broadcast rather than `broadcast_collection_to`.
- **Where:** `lib/phlex/reactive/collections.rb#replace_streams`
- **Proven by:** `spec/phlex/reactive/settles_spec.rb:"re-renders the row in place with no count churn (a replace moves no boundary)"`
- **Origin:** cubic learning 94f127d5, generalised from the settle path to every caller

### A collection reply binds the container as `token_component`, or the list is act-once-only
- **Holds because:** an appended child row carries its OWN token, not the container's, and does not re-render the container's root — so the endpoint's target-scoped guard correctly decides the container still needs a refresh. If the collection verb did not set `token_component`, the reply would carry no fresh container token and the second add would POST a stale one.
- **Where:** `lib/phlex/reactive/response.rb` (the `build_collection_*` verbs); `app/controllers/phlex/reactive/actions_controller.rb#response_streams` (guard 1)
- **Proven by:** `spec/phlex/reactive/collection_streams_spec.rb:"binds the container as token_component so its token rolls forward"`, `:"binds the container as token_component so repeated removes work (cosmos#1939)"`
- **Origin:** the specs' own cosmos#1939 reference; recorded here because the endpoint guard and the reply verb have to agree

### A row identifier may always be an already-built dom-id String, on every path
- **Holds because:** `reply.remove(id, from:)`, `Settle#remove` and `Collections.row_remove_stream` all accept one, so any new consumer that assumes a record will raise for a caller doing something the rest of the API allows. The peer broadcast path is where this was actually missed; see [`async-actions.md`](async-actions.md).
- **Where:** `lib/phlex/reactive/collections.rb#row_remove_stream`; `lib/phlex/reactive/pending.rb#row_dom_id`; `lib/phlex/reactive/streamable.rb#broadcast_collection_row`
- **Proven by:** `spec/phlex/reactive/collections_module_spec.rb:"accepts an already-built dom-id string"`, `spec/phlex/reactive/collection_streams_spec.rb:"accepts a dom-id string as well as a model"`
- **Origin:** PR #250 (the peer path was the one caller that had missed it)

Related: [`../streaming/summary.md`](../streaming/summary.md), [`async-actions.md`](async-actions.md).
