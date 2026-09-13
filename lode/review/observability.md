# Review rules: instrumentation, error reporting and the APM adapters

### An error reporter is handed a fresh SNAPSHOT of the context, never the live event hash
- **Holds because:** the same mutable hash is the `ActiveSupport::Notifications` payload, and the notifier adds `:exception` / `:exception_object` to it during unwinding — after `report_error` has already dispatched. A reporter that retains the hash would later read keys the gem never promised it, silently widening the name-only contract. `report_error` forwards `context.slice(*ERROR_CONTEXT_KEYS)` — `:component`, `:action`, `:outcome` — to the resolved APM adapter and to every `on_action_error` hook, each call wrapped in `safely_report` so a broken reporter can never replace the original 500.
- **Where:** `lib/phlex/reactive.rb#report_error`, `ERROR_CONTEXT_KEYS`, `#safely_report`
- **Safe direction:** a reporter seeing too little is a missing tag; a reporter seeing too much is a token or a param in an APM.
- **Proven by:** `spec/requests/apm_error_spec.rb:"forwards a name-only SNAPSHOT — mutating the live event hash after does not leak in"`, `:"does NOT carry token/params/state to the reporter (name-only context)"`
- **Origin:** PR #210

### A built-in APM adapter resolves to a STABLE instance per symbol
- **Holds because:** `Subscriber.install` keys its idempotency on adapter identity (`@adapter.equal?(adapter)`), and two separately-`new`'d instances of one class are never `equal?`. `APM.detect` calling `klass.new` per invocation therefore made `attach!` uninstall-and-resubscribe every time — contradicting its own documented "a second call with the SAME adapter is a no-op" — across console reloads, re-run engine initialization and any future hot-reload path. `detect` now memoizes `built_in_instances[apm] ||= klass.new`. The gap had been untested because the idempotency spec only exercised a stored custom-adapter *instance*, which satisfies `equal?` naturally.
- **Where:** `lib/phlex/reactive/apm.rb#detect`, `built_in_instances`; `lib/phlex/reactive/apm/subscriber.rb#install`
- **Proven by:** `spec/phlex/reactive/apm/attach_spec.rb:"resolves a built-in Symbol to a STABLE instance so attach! stays idempotent"`, `:"is idempotent for the same adapter (no double subscription)"`
- **Origin:** PR #210

### An adapter probes the vendor SDK's method shape, never its version
- **Holds because:** AppSignal 4.x removed the positional tags argument from `set_error` and requires the block form; 3.x accepts the hash. Pinning a major, or branching on a version string, would make the adapter wrong on one of them and would break the moment either shipped a change. `record_error` branches on `::Appsignal.method(:set_error).arity != 1` — the pgbus capability-gate posture applied inside a gem: ask the thing you are about to call.
- **Where:** `lib/phlex/reactive/apm/appsignal.rb#record_error`, `#set_error_takes_tags?`
- **Proven by:** `spec/phlex/reactive/apm/appsignal_spec.rb:"on AppSignal 3.x passes the tags positionally to set_error"`, `:"on AppSignal 4.x uses the block form (set_error(error) { add_tags(...) })"`
- **Origin:** PR #210

### The observation path never changes what propagates
- **Holds because:** `report_action_error` runs on the endpoint's catch-all rescue and is followed immediately by a bare `raise` of the ORIGINAL error, so Rails' own error reporting and the app's middleware fire exactly as they would without it. Every step inside is best-effort: the reporters are isolated in `report_error`, and the `error_flash` render degrades to nil when the configured lambda raises. The status never changes — this catch adds no new 4xx.
- **Where:** `app/controllers/phlex/reactive/actions_controller.rb#report_action_error` and the final `rescue => e` in `#create_action` and `#deferred_action`
- **Proven by:** `spec/requests/apm_error_spec.rb:"still re-raises the ORIGINAL error when an on_action_error hook itself raises"`, `:"still re-raises the ORIGINAL error even when the error_flash lambda itself raises"`, `:"renders the error_flash for the crash yet still re-raises (flash does not swallow)"`, `:"reports to the hook BEFORE the flash (report → flash → re-raise ordering)"`
- **Origin:** PR #210, the contract the other three rules on this page were reviewed against

Related: [`../tooling/summary.md`](../tooling/summary.md), [`../core-and-config/summary.md`](../core-and-config/summary.md), [`../endpoint/summary.md`](../endpoint/summary.md).
