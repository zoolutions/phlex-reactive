# Testing Rules

## TDD Workflow

Follow RED → GREEN → REFACTOR:

1. **RED**: Write a failing test first
2. **GREEN**: Write minimal code to pass
3. **REFACTOR**: Improve code while keeping tests green

## The test layers

phlex-reactive tests in four layers, cheapest first, all via `spec/dummy`:

| Layer | Path | Boots | Use for |
|-------|------|-------|---------|
| Unit | `spec/phlex/**` | nothing (or stubbed verifier) | identity signing, the Component/Streamable DSL, capability gate |
| Request | `spec/requests/**` | dummy Rails app | the action endpoint: token verify, default-deny, param coercion, 404/400, record re-find |
| Broadcast | `spec/requests/*_broadcast_spec.rb` | dummy + Turbo test helpers | `broadcast_*_to` emits the right Turbo Stream to the right stream |
| System | `spec/system/**` | dummy + Capybara/Playwright | the real browser loop: click → morph, no reload, rapid-click race |

## Coverage Expectations

- **80% minimum** for all code
- **100%** for the security-critical paths:
  - identity sign/verify (tamper, wrong key, wrong purpose)
  - the action endpoint (default-deny, schema coercion, authorization 403)
  - the capability gate (false on pgbus absent / too old, true when present)

## RSpec Conventions

```ruby
let(:todo) { Todo.create!(title: "x") }
subject(:component) { described_class.new(todo:) }

context "when the action is undeclared" do
  it "is forbidden" do
    post_action(klass, payload:, act: "drop_table")
    expect(response).to have_http_status(:forbidden)
  end
end
```

## Browser specs (system)

- Drive via stable `data-testid` selectors, not glyph text (e.g. the `−` button).
- Use **waiting matchers** (`have_css(..., text:)`, `have_field(with:)`) as the
  barrier for the async morph — never assert a snapshot value right after a click.
- Prove "no full-page reload" by setting a `window.__marker` and re-reading it.
- The browser suite runs under two REAL servers — Puma (default) and Falcon
  (`CAPYBARA_SERVER=falcon`). CI runs both in a matrix; `rake spec:system_servers`
  runs both locally. A reactive round trip must pass under sync (Puma) AND async
  (Falcon). No webrick — it isn't a real server.
- Every system example runs under a watchdog (`spec/system/support/example_timeout.rb`,
  issue #320): 90 s by default, `it "…", timeout: 120` per example,
  `SYSTEM_EXAMPLE_TIMEOUT=…` for the run, `0` to disable (debugger). A timed-out
  example fails naming its bound ("is the server wedged?") and ends the run.

## pgbus in tests

- pgbus is a dev/test dep (Ruby ≥ 3.3), `require: false`. It needs PostgreSQL.
- Unit/request/system specs run WITHOUT pgbus (Action Cable / `require: false`),
  so the default suite needs no Postgres.
- pgbus-specific specs (exclude:/presence/typed events) must guard with
  `defined?(Pgbus)` (or a tag) and assert BOTH paths: pgbus present AND the
  capability-gate fallback. The "old pgbus shape" double (a `broadcast` without
  `:exclude`) is the regression guard for the `ArgumentError`.

## Test Checklist

- [ ] Tests written BEFORE implementation; RED verified
- [ ] `bundle exec rspec spec/phlex spec/requests` green
- [ ] Browser suite green for client-touching changes
- [ ] Edge cases: tampered token, undeclared action, missing record, unauthorized
- [ ] pgbus-present AND pgbus-absent paths both covered for any pgbus feature
- [ ] `bundle exec rubocop` passes
