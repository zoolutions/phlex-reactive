# Review rules: documentation prose

Prose drifts from code faster than tests do, and reviewers read the prose. These are the wordings this repository has already had to correct.

### A "nothing leaves the browser" claim has to name its exceptions
- **Holds because:** the client-ops page said a `JS` chain sends nothing anywhere, while two of the seventeen verbs do reach outside the page: `submit` hands the form to its own native or intercepted submit path, from which the form may POST or navigate, and `paste_into` reads the system clipboard. The page now names both as the deliberate exceptions and scopes the local-only claim to everything else. Any new op that touches the network, the clipboard or navigation joins that enumeration in the same PR.
- **Where:** `docs/app/views/docs/pages/example_client_ops.rb`; the op list in `lib/phlex/reactive/js.rb`
- **Proven by:** no automated test — docs prose has none. `grep` the README and `CHANGELOG.md` for the same claim before shipping a wording change.
- **Origin:** PR #229

### Describe the ordering the runtime actually produces, not the one the API reads like
- **Holds because:** `paste_into` starts `readText().then(...)` and returns immediately, so chained siblings apply WITHOUT waiting; the value write, the bubbling `input` event and the focus all happen when the read resolves. The docs said "on click it awaits", which documents an ordering the code does not have — and the same sentence had been copied into the CHANGELOG. When a fire-and-forget call is documented, say fire-and-forget, and grep the changelog for the same sentence.
- **Proven by:** no automated test — the docs request specs render every page but assert nothing about wording.
- **Where:** `docs/app/views/docs/pages/example_client_ops.rb`; `CHANGELOG.md`
- **Origin:** PR #229

### A removed setting is removed from every place that mentions it, each carrying why it is absent
- **Holds because:** an app that reads the config, the README or the docs page in isolation must not come away believing it can tune something that does not exist. When `settle_token_ttl` was dropped it went from the config, the README, the docs page and the CHANGELOG together, each replaced with a short note that a settle's wait is bounded by the job, not a TTL — and a spec asserts `Phlex::Reactive` does not respond to it, so it cannot come back by accident.
- **Where:** `lib/phlex/reactive.rb` (the NOTE), `README.md`, `docs/app/views/docs/pages/async_actions.rb`, `CHANGELOG.md`
- **Proven by:** `spec/phlex/reactive/settle_config_spec.rb:"exposes no settle_token_ttl — a settle has no pull lane for a token to govern"`
- **Origin:** cubic learning 6bc297de; PR #250

### A demo page's visible controls all work
- **Holds because:** the docs site is the demo app, so a broken control on a page is a broken claim about the gem. A collection row rendered a dismiss button that dispatched an action the container never declared, so clicking it errored instead of acting. The fix was a row variant whose control dispatches an action the container DOES declare — not declaring the extra action, because a synchronous dismiss would have muddied what an async-archiving demo teaches. A demo change carries a comment saying why it did not reuse the obvious existing component.
- **Proven by:** no test asserts a demo's controls are wired to declared actions; the docs system suite drives some pages but not this one.
- **Where:** `spec/dummy/app/components/archive_queue_component.rb`, `archive_row_component.rb`
- **Origin:** PR #250

Related: [`../docs-site/summary.md`](../docs-site/summary.md), [`release-and-changelog.md`](release-and-changelog.md).
