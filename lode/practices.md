# Practices

The binding rules live in `../CLAUDE.md` and `../.claude/rules/` (coding-style, testing, performance, git-workflow, agents). This file adds the practices those do not state, read off the code and off accepted review findings. The specific rules with their proofs are in `review/`.

## Optionality

- A feature that needs another gem is gated on a **capability probe of the thing you are about to call**, not on the constant existing. `pgbus_streams?` asks `Stream.instance_method(:broadcast).parameters` for `:exclude`; `defer_push_capable?` additionally checks `SignedName.respond_to?(:sign)` and `ActiveJob::Base`; `APM::Appsignal.available?` checks the SDK constant. A version string is never the gate.
- An optional gem's constants must not be referenced at class-definition or eager-load time. Three paths are held back for exactly this — `mcp/` and `test_helpers/system.rb` are `loader.ignore`d (their classes subclass the `mcp` gem / need Capybara at definition), and `deferred_render_job.rb` is `do_not_eager_load`ed (it subclasses `ActiveJob::Base`, so it must autoload on first reference, behind `defer_push_capable?`, rather than at boot). The loader config at the foot of `lib/phlex/reactive.rb` says why for each.
- Missing capability **degrades and says so once per process**, never per call: `Defer.warn_stream_degraded`, `Pending.warn_no_lane`, `APM.warn_and_nil`. A per-reply warning would bury the signal.

## Failing loudly, at the right time

- Declaration-time over request-time. An unknown param type raises `UnknownParamType` when `action` runs (`ParamSchema.compile`); an unknown effect name raises at `reactive_effects` / `Phlex::Reactive.effects=`; a bad `reactive_on_complete` chain raises at class load; a mirror target that is not an id selector raises at declare time.
- Render-time over click-time, but only in dev/test. `on(:typo)` raises at render **only** under `verbose_errors` and **only** when the component declares at least one action of its own — a cross-component dispatch helper with an empty registry is a supported pattern, and production must not 500 on a stale page after a deploy.
- A removed API gets a stub that raises with the exact rewrite, not a silent absence: `Streamable::REMOVED_BROADCASTS` (11 methods), `Response::REMOVED_CLASS_VERBS` (10), `Helpers::REMOVED_ON_KWARGS`, `reactive_compute_def`, `flash_builder`. Clean break plus a guided error; never an alias kept "for compatibility".
- A dead construct is a failure, not a no-op: an empty ops chain, an empty `reply.also`, `reply.defer` on a redirect, a `reactive_on_complete` with no ops.

## Enumerate once

- A `records` argument may be a lazy Enumerator or an ActiveRecord Relation. Walk it ONCE into an Array before two consumers read it (`Pending.materialize`), or the marked targets and the enqueued jobs can disagree.
- A size resolver is usually a DB count. Resolve it once per delta and pass the same value to every decision that reads it (`Collections.size_of` → `count_refresh` + `empty_toggle`), or a concurrent write between the two reads ships a count that disagrees with the empty-state toggle beside it.

## Caching on the render path

- The identity memos read on every render (`@reactive_record_ivar`, `@reactive_state_ivars`) are bare `defined?`/`||=` with NO generation compare. Coherence comes from the WRITE side: `Component::Registry.bump!` sweeps them off the declaring class and every descendant. Declarations are class-load-shaped and rare; renders are not.
- Anything holding a view context is cached PER THREAD, keyed on the renderer object's identity AND a generation integer, and reset from the engine's `to_prepare`. An ActionView context carries a mutable output buffer, so one shared instance can interleave content across threads.

## Threading request state

- Per-request values reach off-request code through a `with_*` / `current_*` pair on `Phlex::Reactive` that saves and restores in `ensure` (`with_connection_id`, `with_url_options`, `with_defer_binding`, `Pending.with_handle`, `Defer.with_real_render`, `Authorization.with_tracking`). `Thread.current` is fiber-local in Ruby, so Falcon's fiber-per-request model is safe.
- A broadcast render deliberately CLEARS the actor's url_options (`with_url_options(nil)`): subscribers can be on other hosts, so "URLs in broadcast-rendered components are host-relative" is the broadcast contract.

## Strings that reach the browser

- Every interpolation into a hand-built `<turbo-stream>` goes through `ERB::Util.html_escape` (or `CGI.escapeHTML`) before `.html_safe`, and the comment says the buffer is safe by construction. Concatenate html_safe pieces; `safe + plain` escapes the whole tag.
- Caller-supplied content has one contract everywhere (flash, `also`, defer placeholder): a Phlex component renders through the configured renderer, an `html_safe` String passes verbatim, any other value is escaped data.
- The attribute allowlist is enforced on BOTH sides and in BOTH doors — the `JS` builder at build time, `JS.assert_ops_allowed!` on any raw `[[op, args], …]` escape hatch, and the client interpreter again.

## Broadcasts are not replies

- An op that acts on the actor's own focus, form or clipboard is refused on a broadcast (`Streamable::BROADCAST_REFUSED_OPS`): broadcasting it would steal focus, force-submit or read the clipboard in every subscriber's tab.
- Peer delivery is best effort and never fails the job (`Settles#deliver_peers`); the actor's message is already on the wire and a retry would re-send it.

## Docs and changelog

- The CHANGELOG declares Keep a Changelog, so `### Added` precedes `### Fixed` and each `## [Unreleased]` carries at most one block per section — merge, never append a second.
- A behaviour change updates the matching page under `docs/app/views/docs/pages/` in the same PR, and a removed setting is removed from the config, the README, the docs page and the CHANGELOG together, with a short note on why it is absent.
