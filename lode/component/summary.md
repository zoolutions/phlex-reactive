# Component: the declaration DSL and the view helpers

`lib/phlex/reactive/component.rb` and `component/{dsl,helpers,identity,lazy,registry}.rb`, plus `client_bindings.rb`, `param_schema.rb`, `show_conditions.rb`, `js.rb` and `effects.rb`.

## The include stack

`include Phlex::Reactive::Component` pulls in, in order: `Streamable` (render/broadcast/`#id`, mixed first so its methods sit below the component's own), `ClientBindings` (= `Component::DSL` + `Component::Helpers`), `Identity`, `Lazy`. `ClientBindings` is the ONE implementation of the client-only surface and is includable on its own — a token-bearing component is a SUPERSET of a client-only one, not a fork. The three server-action macros (`action`, `reactive_record`, `reactive_state`) call `require_server_actions!`, which keys on `Identity` being in the ancestry, so they raise at class-definition time on a `ClientBindings`-only class rather than silently signing nothing.

Four `Data.define` declaration shapes live on `Component` itself: `ActionDefinition`, `ComputeDefinition`, `OnCompleteDefinition`, `CollectionDefinition` (with `#size_for`, which `instance_exec`s the declared `size:` proc against the bound container). `ActionDefinition` is deliberately not named `Action`: this module sits in every reactive component's ancestry, so a bare `Action` constant shadows a host app's Phlex kit component of the same name under lazy autoloading. **Keep every constant here suffixed or implausible as a kit component name.**

## Registry: one inheritance semantic

`Component::Registry` gives all twelve class-level registries (`actions`, `state_keys`, `collections`, `computes`, `on_completes`, `record_key`, `scope`, `dirty`, `lazy`, `effects`, `skip_all`, `skip_actions`) the same semantic: **resolve through the superclass at read time**, memoized per class against a process-wide generation counter bumped on any write. Hash-shaped registries merge ancestors-first with the nearest declaration winning, and the resolved hash is FROZEN (it is the default-deny dispatch table); list-shaped ones concatenate ancestors-then-own; scalar-shaped ones take the class's own declaration if present, else the nearest ancestor's.

The hot-path contract is the part to preserve: the generation check gates registry RESOLUTION only. `Identity`'s `@reactive_record_ivar` and `@reactive_state_ivars`, read on every `reactive_token`, stay bare `defined?`/`||=` with no per-read compare, and are invalidated at WRITE time — `bump!` removes them from the writing class and recurses through `klass.subclasses`. Storage is all on the component class itself, so a Zeitwerk reload's fresh class object starts clean and nothing global retains a reference to app classes. `WRITE_MUTEX` serializes the generation increment; `resolution_cache` writes the new (empty) cache BEFORE the new generation so a concurrent reader never finds the stale one.

## Identity

`reactive_identity_payload` builds `{"c" => class name}` and adds:

- `"gid"` — only for a present, PERSISTED record. `signable_gid?` treats anything not responding to `persisted?` as signable; an unsaved AR draft has no id and `to_gid` would raise `MissingModelIdError`, so the gid is omitted and the declared `reactive_state` is the draft seed.
- `"s"` — `{ key => ivar.as_json }` for every `reactive_state` key, walked through the precomputed `[string_key, ivar_symbol]` pairs so no String/Symbol is allocated per render.

`from_identity` (on `DSL`) rebuilds from a verified payload: locate the record by GlobalID (raising `ActiveRecord::RecordNotFound` when it is gone), or, for a draft token with no gid, omit the kwarg entirely — with `ensure_draft_default!` raising a guided `Phlex::Reactive::Error` when `initialize` requires the record keyword, instead of a bare missing-keyword `ArgumentError` deep inside `new(**kwargs)`. State keys are restored by KEY PRESENCE, not truthiness, so a signed `nil` or `false` round-trips distinctly from an absent key.

## Lazy initial mount

`Lazy` overrides Phlex 2's `around_template` (not yield-then-decorate — the shell REPLACES the template). A `reactive_lazy` component's page-embedded first render emits a shell owning the component's `id` with `data-reactive-defer-token` on the root; the client's `connect()` probes it and enters the same fetch path a `reply.defer` directive uses. **Lazy applies only to the initial mount:** every render that goes through the reactive machinery runs inside `Defer.with_real_render` (`Streamable.render_component` and `Phlex::Reactive.render` both set it), so an action reply, a broadcast, the defer endpoint and the class stream builders all render the REAL template. The shell's token is minted `unbound: true` — the page render happens before a session exists.

## The declaration macros (`Component::DSL`)

`reactive_record`, `reactive_state`, `reactive_scope`, `reactive_dirty`, `reactive_effects`, `reactive_lazy`, `action`, `skip_verify_authorized`, `reactive_collection`, `reactive_compute`, `reactive_on_complete`.

- `action(name, params: {})` compiles the schema ONCE at declaration, so a typo'd type symbol raises `UnknownParamType` at class load. `params:` also accepts a Symbol naming a registered `Phlex::Reactive.param_schema`.
- `reactive_scope` and `action` cross-check each other (`assert_no_scope_double_nesting!`) in both declaration orders: a schema already nested under the scope key would be double-peeled at the endpoint.
- `reactive_compute`'s `inputs:` takes three shapes, all degenerate cases of the permit form: a pure Hash (typed), an Array with a trailing type Hash (bare symbols default to `:number`), or a bare Array (untyped — nil types, so the wire stays byte-identical and the client keeps numeric coercion). `mirror:` targets are validated at declare time against `MIRROR_ID_SELECTOR` — id selectors only, never arbitrary selectors.
- `reactive_on_complete` compiles its conditions through `ShowConditions.normalize` and its `run:` chain through the same allowlist a raw ops list gets. `reactive_on_complete_attr` memoizes the JSON wire per class against `Registry.generation`, because `reactive_attrs` is the token-signing hot path — same trick as `reactive_effect_attrs`, which memoizes against both `Registry.generation` and `Phlex::Reactive.effects_generation`.

## The view helpers (`Component::Helpers`)

`reactive_attrs` builds the root's `data:` and is where every opt-in surfaces: `controller: "reactive"` always; `reactive_token_value` only when `respond_to?(:reactive_token, true)` (the include-private check — `reactive_token` is private); then `reactive_debug`, `reactive_verbose`, `reactive_scope`, the resolved effect attrs and the on-complete JSON, each omitted entirely when off so the wire stays byte-stable. **Boolean-true attributes are written as the STRING `"true"`**: Phlex renders a `true` attribute valueless, which `getAttribute` reads as `""` — falsy in JS — so the client guard would never fire.

`reactive_root(**overrides)` is the whole root in one spread: it binds `id:` to the SAME element as `reactive_attrs`, because `id:` on a child leaves the controller root's `id` empty and the client self-matches its next token by `this.element.id`. Overrides go through Phlex's `mix` (deep merge) so a caller's `class:`/`data:` never clobbers the controller/token data; `id` is resolved separately as a clean replace, since `mix` would string-concat two ids.

`on(action_name, …)` emits the dispatch descriptor: `event[@window]->reactive#dispatch[:once]`, the action name, the params JSON (`"{}"` when empty), and optional `debounce`/`throttle` (mutually exclusive — declaring both raises), `confirm`, `optimistic`, `busy`, `outside`, `window`. It forces `type="button"` for a click trigger, EXCEPT when `optimistic` declares `checked: :keep` — that hint exists to let a click-bound checkbox flip natively. `on_client(event, ops)` is the zero-round-trip sibling: a non-empty `JS` chain only, no token, no POST.

The rest of the helper surface is field/binding compilation: `reactive_field`/`reactive_input`/`reactive_select`/`reactive_text`, `reactive_show`/`reactive_show_targets`/`reactive_filter`, `reactive_listnav`, `reactive_tags*`, the nested-attributes family (`reactive_nested_list`/`_template`/`_row`/`_add`/`_remove`, `nested_field_name`, `nested_attributes`, `nested_update!`), `reactive_persist`, `busy_on`, `reactive_compute_attrs`. Each validating helper raises at render time on a bad selector, identifier or scope rather than emitting a binding that silently matches nothing in the browser.

## ParamSchema

Compiled once per action. A type is a scalar Symbol, a Hash schema (nested object), or a one-element Array (array of that). Eight built-in types ship: `string`, `integer`, `float`, `boolean`, `file`, `date`, `datetime`, `decimal` — `file` and the composites are handled structurally in `#coerce`, so their registry entry exists only for compile-time validation.

The coercion contract is **drop, don't fabricate**. `DROP` is a public sentinel a custom `param_type` returns to reject a value; a dropped key is simply not assigned, so the method's keyword default applies exactly as if the client had omitted it.

| Input | Result |
|---|---|
| an undeclared key | dropped (no mass assignment) |
| `"abc"` for `:integer` | `0` — `to_i`'s own semantics, kept verbatim from the pre-extraction controller |
| an unparseable `:date`/`:datetime`/`:decimal` | `DROP` (the parse is rescued to it) |
| a non-uploaded value for `:file` | `DROP` — a file is duck-typed on `original_filename` + `read`, never a class name |
| a scalar where a Hash schema is declared | `DROP`, never a fabricated `{}` |
| a scalar where an Array is declared | `DROP`, never a fabricated `[]` |
| a Rails index hash `{"0" => …}` for an Array | coerced in index order |
| an array whose every element drops | `DROP`; a genuinely empty input array stays `[]` |
| a malformed TOP-LEVEL container | normalized to `{}` — the top level holds the kwargs, so a bad container means "no params" |

`to_param_hash` also expands bracket notation (`invoice[date]` → `{"invoice" => {"date" => …}}`, `items[0][qty]` → the index form), deep-merging so a bracket key and a pre-nested object for the same key coalesce whichever arrives first. Under `verbose_errors` a collector accumulates `[bracketed_path, :undeclared|:uncoercible]`; with the flag off the collector is nil and every diagnostic branch early-returns.

## ShowConditions

The ONE conditions language for `reactive_show`, `reactive_show_targets`, `reactive_filter` and `reactive_on_complete`. Ruby values compile to a DNF wire shape — an array of groups, terms AND within a group, groups OR — and `ShowConditions.match?` evaluates that same shape in Ruby so the server's first-paint `hidden:` and the client's live toggling cannot drift. `spec/fixtures/show_predicate_vectors.json` is the shared parity fixture both sides run.

Value language: scalar → equals (stringified), `true`/`false` → `"true"`/`"false"`, `nil` → `""`, Array → membership, a Range → `gte`/`lte`/`lt` terms, `{ length: … }` → the `len_*` family counted in CODEPOINTS (so Ruby's `String#length` and JS's `[...value].length` agree on multibyte). `unless:` negates by De Morgan and a bounded range's complement splits the group. There is no expression surface: every term is a declared literal predicate. A referenced field absent from the values map reads as `""` (fail-closed).

## JS ops and Effects

`Phlex::Reactive::JS` is an immutable chain of 17 verbs (`show`/`hide`/`toggle`, the three class ops, the three attr ops, `focus`/`focus_first`, `submit`, `paste_into`, `text`, `dispatch`, `persist_state`/`persist_clear`). Targets resolve WITHIN the component's root by default (nested reactive roots excluded); `:root` is the root itself; `global: true` opts one op out. The attribute allowlist refuses `on*` (XSS), the six URL-bearing attributes and `style`, enforced at build time by the builder AND by `JS.assert_ops_allowed!` on every raw `[[op, args], …]` escape hatch — and again by the client interpreter.

`Effects` owns the enter/exit/update vocabulary: five built-ins (`fade`, `slide`, `scale`, `highlight`, `shake`), `:random`, `false` to disable a hook, or custom `{ during:, from:, to: }` legs compiled to the `[during, from, to]` wire array. Resolution is global ⊕ component ⊕ per-call, most specific wins; `false` survives normalization so a component-level `update: false` can cancel a global hook. Validation happens at WRITE time. See `../review/client-runtime.md` for the blank-leg rule.

Related: `../endpoint/summary.md` (what the endpoint does with these declarations), `../client-runtime/summary.md` (the other half of every binding).
