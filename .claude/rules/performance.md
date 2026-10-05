# Performance Rules

phlex-reactive must be fast in the places that run on every interaction. These
rules make performance a standing part of every change, not an afterthought.
See the performance page (`docs/app/views/docs/pages/performance.rb`) for the
harness and the current numbers.

## The prime directive

**Measure before you change. Measure after. Report both, honestly.**

A performance claim without a same-machine before/after is not allowed in a PR
or a commit message. If you didn't baseline, you don't have a delta — say
"measured after only" or go capture the baseline (`/perf` automates this with a
worktree).

## When performance is in scope

Any change to a **hot path** must come with a bench and a before/after:

| Hot path | File |
|----------|------|
| Component re-render | `lib/phlex/reactive/streamable.rb` (`render_component`, `to_stream_replace`, `turbo_stream_builder`) |
| Identity token signing | `lib/phlex/reactive/component.rb` (`reactive_token`, `on`, `reactive_attrs`) |
| Param coercion | `app/controllers/phlex/reactive/actions_controller.rb` (`coerce_params` and friends) |
| Broadcast render | `lib/phlex/reactive/streamable.rb` (`broadcast_*_to`) |
| Client dispatch | `app/javascript/phlex/reactive/core.js` (and `features/*.js`) |

A pure docs/test/refactor change with no hot-path edit does not need a bench.

## Always Do

1. **Baseline first** — capture `main` (or pre-change) numbers BEFORE editing.
   Run `rake bench:micro` and, for request-shaped work, `rake bench:request`.
2. **Add a bench for a new hot path** — `benchmark/micro/<name>.rb` using the
   shared `BenchSupport` harness. `rake bench:micro` discovers it automatically.
3. **Report throughput AND allocations** — i/s + obj/call. Flag any non-zero
   *retained* per render (a leak).
4. **Distinguish method-level from request-level wins** — a 2× faster render
   does NOT mean 2× faster requests (Rails stack + DB dominate); it means ~2× on
   broadcast fan-out and less GC pressure. Say which the number is.
5. **Update the docs + CHANGELOG** — if representative numbers moved, update
   the performance page (`docs/app/views/docs/pages/performance.rb`); note the
   change under a `perf:` CHANGELOG entry.
6. **Re-sync the vendored client** — any `core.js` or `features/*.js` edit
   re-copies the rebuilt files to `spec/dummy/public/vendor/` (AGENTS.md has
   the list); run `bun test
   spec/javascript`.

## Never Do

1. **Never claim a speedup without a measured before/after.** No "this should be
   faster." Prove it or don't say it.
2. **Never optimize a cold path** the bench shows isn't hot — three clear lines
   beat a clever micro-optimization that obscures behavior for no measured gain.
3. **Never break a security/correctness invariant for speed** — the signed
   identity, default-deny, schema coercion, and pgbus optionality are not
   negotiable. A faster wrong answer is wrong.
4. **Never trade carefully-tested behavior for a marginal allocation win.** The
   nested-param coercion (issues #16/#21/#24) is correctness-critical; don't
   rewrite its deep-merge for ~10% fewer objects on a path that isn't the
   bottleneck. Hoisting a regex to a constant: yes. Rewriting the algorithm: only
   if the bench proves it matters and the tests still pass.
5. **Never add a hard CI perf gate on a flaky threshold** — the `bench` CI job is
   run-and-report (uploads an artifact), not a merge blocker. Shared runners are
   too noisy for a hard cutoff.

## Caching for speed — the correctness guards

When memoizing on the hot path (we do this for the view context, the stream
builder, the flash builder, token ivar symbols):

- **Key the cache on what can change.** The view context is keyed on the
  configured renderer's identity, so swapping `Phlex::Reactive.renderer`
  rebuilds it. A bare `@x ||=` that ignores a changeable input serves stale data.
- **Reset on Rails code reload.** Anything holding a controller/view-context
  instance must reset on `config.to_prepare` (the engine does this) — otherwise
  dev serves a reloaded class from a stale memo.
- **Don't cache values that legitimately rotate.** The CSRF token and the pgbus
  connection id are read live on the client on purpose; caching them sends stale
  values. Only the page-stable action path is cached.

## Checklist (before marking perf work complete)

- [ ] Baseline captured BEFORE the change (same machine, same script)
- [ ] After numbers captured; before/after in the PR body
- [ ] A bench exists for every hot path touched
- [ ] Throughput + allocations reported; retained-per-render is 0
- [ ] Method-level vs request-level framing is honest
- [ ] Performance page (`docs/app/views/docs/pages/performance.rb`) + CHANGELOG updated if numbers moved
- [ ] Vendored client re-synced + JS tests green (if the client changed)
- [ ] `bundle exec rspec spec/phlex spec/requests` still green
- [ ] No security/correctness invariant traded for speed
