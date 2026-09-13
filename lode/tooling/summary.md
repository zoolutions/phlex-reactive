# Tooling: doctor, inspector, MCP, APM, generators, test helpers

The surfaces an adopter and an agent touch that are not the round trip itself. Everything here is **read-only or install-time**, and each is optional-dependency-tolerant in the same way the pgbus path is.

## `Doctor` — "nothing happens, why?"

`lib/phlex/reactive/doctor.rb`, driven by `bin/rails phlex_reactive:doctor` (`lib/tasks/phlex_reactive.rake`). Five closed integration papercuts (boot/eager-load, route shadowing, a lost request, an unregistered Stimulus controller, an importmap 404) only ever surfaced after something already broke; the doctor turns them into a checklist you run before and after setup.

`build_checks` returns nine checks in this order: `route_check`, `defer_route_check`, `stimulus_check`, `csrf_check`, `verifier_check`, `base_controller_check`, then the three registry-reading ones `action_check`, `id_check`, `authorization_check`. Each answers a `Check` value object — a status (`:ok` / `:fail` / `:unknown`), a human message, and on anything but `:ok` a `fix:` line.

Two contracts hold it in place:

- **It is read-only.** It never mounts a component, mutates state or crosses the default-deny boundary; the worst it does is a throwaway sign then verify round trip and one pass over the loaded `Streamable` registry.
- **`Doctor.run` returns true when nothing FAILED** — an advisory `?` does not count — so the rake task can `abort unless` it and a setup script or CI can gate on the exit code. `GLYPHS` are plain Unicode with no ANSI, so log capture reads cleanly.

`run` calls `Rails.application.eager_load!` itself, because the three component checks read the `Streamable` registry and it is empty otherwise.

## `Inspector` and `Inspector::Report`

`inspector.rb` walks the same registry into two `Data` shapes — `ActionInfo(name, params, source_location, definition)` and `ComponentInfo(klass, name, path, record_key, state_keys, actions)` — and `inspector/report.rb` renders them. Three rake tasks consume the pair:

| Task | Output |
|---|---|
| `phlex_reactive:actions` | every declared action as `component \| action \| params \| file:line \| auth`; `FORMAT=json` for tooling |
| `phlex_reactive:find[query]` | a fuzzy component match plus its actions with the method's source |
| `phlex_reactive:doctor` | the checklist above |

Names, paths and schemas only — no token, no state, no param values. The same discipline the instrumentation payloads keep.

## MCP: the diagnostic server

`mcp.rb` plus `mcp/{base_tool,runner,server}.rb` and five tools — `phlex_reactive_components`, `phlex_reactive_actions`, `phlex_reactive_find`, `phlex_reactive_doctor`, `phlex_reactive_config`. Run over stdio with `bin/rails phlex_reactive:mcp`.

The `mcp` gem is **optional and absent from the gemspec**. The whole `mcp/` subtree is `loader.ignore`d because its tools subclass `MCP::Tool` at class-definition time; `MCP.load!` requires the gem — raising a `Phlex::Reactive::Error` naming the Gemfile line when it is absent — and then requires the tree in dependency order. `mcp.rb` itself references no gem constant at load time, so Zeitwerk autoloads it normally.

The runner's one hard rule: **nothing but JSON-RPC frames may reach stdout**, so a host app's chatty initializer breaks the transport.

## APM adapters

`apm.rb` plus `apm/{adapter,appsignal,datadog,sentry,subscriber}.rb`. `Phlex::Reactive.apm` takes a Symbol, a custom adapter object (responding to `record_action` / `record_error`), or nil. `BUILT_INS` maps three symbols — `:appsignal`, `:sentry`, `:datadog` — to adapter class names.

Resolution is deferred to the engine's `after_initialize`, so a vendor SDK loaded by an app initializer is already there. Two rules are load-bearing and both came out of review:

- **`detect` memoizes the instance per symbol** (`built_in_instances[apm] ||= klass.new`). `Subscriber.install` keys idempotency on `@adapter.equal?(adapter)`, so a fresh `klass.new` per call would uninstall and re-subscribe on every `attach!` instead of no-op'ing.
- **The adapter probes the SDK's shape, not its version.** `Appsignal#record_error` branches on `::Appsignal.method(:set_error).arity` — 3.x takes the tags positionally, 4.x needs the block form — so one adapter spans both majors without pinning either. The pgbus capability-gate posture applied inside a gem.

A set-but-undetectable SDK logs ONE warning at boot through `warn_and_nil` and no-ops. No vendor SDK is ever a hard dependency.

## Generators

Three, all under `lib/generators/phlex/reactive/` and all `loader.ignore`d — Rails' generator system owns their discovery and their path/constant scheme is deliberately non-Zeitwerk:

- `phlex:reactive:install` — writes the initializer from `templates/phlex_reactive.rb.erb`, registers the Stimulus controller, prints the next steps.
- `phlex:reactive:component NAME` — the component plus its spec, with `--record` and `--state` class options; the spec is skipped when RSpec is absent.
- `phlex:reactive:claude` — installs the packaged debugging skill from `lib/phlex/reactive/claude/skills/` into the host app and configures the MCP entry. Its `source_root` points into the gem's own `claude/skills`, which the gemspec therefore has to package.

## Test helpers

`test_helpers.rb` is the request-spec surface: `reactive_token_for`, `post_reactive_action`, `post_reactive_multipart` and `run_reactive` — which runs a declared action through the same coercion and transaction wrapper the endpoint uses and hands back a `Result` answering `replace?` / `remove?` / `redirect?` / `streams`.

Its two companions are required conditionally at the foot of the file, which is exactly why both are `loader.ignore`d:

- `test_helpers/matchers.rb` — `have_reactive_replace`, `have_reactive_remove`, `have_reactive_token_for`, each accepting a component instance or a bare DOM id. Required only `if defined?(RSpec::Matchers)`; it defines constants under `RSpec::Matchers`, not under `Phlex::Reactive`. In an `RSpec::Matchers.define` block the `do |arg|` parameter is the EXPECTED value and `match do |actual|` the actual — a RuboCop autocorrect that conflates the two silently guts the matcher, which is why the file carries the cop disable.
- `test_helpers/system.rb` — `wait_for_reactive`, `have_reactive_value`, `have_reactive_text`: polling matchers for the browser suite's async morph, clocked on `Process::CLOCK_MONOTONIC`. Required only `if defined?(Capybara)`, so an eager load in production never defines browser helpers with no Capybara.

Related: [`../core-and-config/summary.md`](../core-and-config/summary.md) (the settings these read), [`../testing-and-ci/summary.md`](../testing-and-ci/summary.md), [`../review/observability.md`](../review/observability.md).
