# Review rules: test hygiene

Two suites here share a process — bun runs every `spec/javascript` file in one, and RSpec shares a global ActiveJob adapter — so leaked state fails a LATER file and the failure names the wrong test.

### A bun test file restores every global it installed, not just the interesting one
- **Holds because:** bun runs `spec/javascript` in ONE process, so a fake `fetch`, `document` or `window` left installed is inherited by whichever file runs next, and the resulting failure depends on execution order. The paste-op suite restored `navigator` and left the other three; all four are now snapshotted at module load and restored in `afterEach`.
- **Proven by:** no automated test can prove the absence of a leak; the guard is that `REAL_*` constants are captured at module load and restored in `afterEach`, which is greppable.
- **Where:** `spec/javascript/reactive_paste_op.test.js` and the sibling files' `afterEach`
- **Origin:** PR #229

### A spec that changes a global adapter captures the previous value and restores THAT
- **Holds because:** hard-coding the restore (`ActiveJob::Base.queue_adapter = :test` in `after`) restores nothing when `before` already set it to `:test`, and leaks `:test` into every following example if the surrounding suite expected something else. An `around` hook captures and restores, and has the side benefit of dropping the instance variable `RSpec/InstanceVariable` would flag in a `before`/`after` pair.
- **Proven by:** no automated test; `RSpec/InstanceVariable` flags the `before`/`after` form, which is the nearest mechanical signal.
- **Where:** `spec/requests/pending_settle_spec.rb` and any spec touching `ActiveJob::Base.queue_adapter`
- **Origin:** PR #250

### An ordering assertion guards its indexes before comparing them
- **Holds because:** `payload.index(...)` returns nil when the stream is missing, and `expect(nil).to be < 3` raises `NoMethodError: undefined method '<' for nil` — a generic crash instead of "the row was never removed". Assert both indexes are non-nil first, so the failure names the real problem.
- **Proven by:** no automated test — it is a property of the assertion itself.
- **Where:** `spec/phlex/reactive/settles_spec.rb` (the `s.move` ordering assertion)
- **Origin:** PR #250

### Not a bug: the confirm suites' `afterAll` resolver reads `window.confirm` lazily and must keep doing so
- **Holds because:** the teardown resolver is a closure — `(message) => Promise.resolve(globalThis.window.confirm(message))` — that resolves `globalThis.window.confirm` at CALL time, not at teardown time, so it delegates to whatever the NEXT file installs rather than wrapping this file's last stub. Nothing can leak either way: every confirm test file reassigns `globalThis.window` to a fresh object in its own `buildController` before stubbing, so a stale `confirm` is discarded before it could be read. Capturing and restoring an "original" would be actively wrong — at module-load time bun provides no `window` at all, so there is no pristine value to capture, and freezing the resolver to this file's last stub would break the lazy delegation the next file relies on. The reviewer verified both cross-file orderings and withdrew.
- **Where:** `spec/javascript/reactive_nested.test.js`, `reactive_confirm.test.js`, `reactive_confirm_conditional.test.js`, `reactive_confirm_resolver.test.js`, `reactive_run_ops_confirm.test.js` — each file's `buildController` and `afterAll`
- **Origin:** PR #223 (CodeRabbit, withdrawn)

### Not a bug: a constant referenced unqualified from a nested module is not a `NameError`
- **Holds because:** `Component::DSL` is lexically nested inside `Phlex::Reactive::Component`, so an unqualified `OnCompleteDefinition` resolves to the `Data.define` beside `ComputeDefinition` and `CollectionDefinition` in `component.rb` — the same path those two already take. A reviewer reading `dsl.rb` alone will report this shape as an undefined constant; the answer is the lexical scope, not a qualification. The reviewer verified and withdrew.
- **Where:** `lib/phlex/reactive/component.rb` (the four `Data.define`s), referenced from `lib/phlex/reactive/component/dsl.rb`
- **Origin:** PR #227 (CodeRabbit, withdrawn)

Related: [`../testing-and-ci/summary.md`](../testing-and-ci/summary.md), [`client-runtime.md`](client-runtime.md).
