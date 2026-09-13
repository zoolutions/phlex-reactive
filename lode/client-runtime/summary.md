# The client runtime

`app/javascript/phlex/reactive/*.js` — five authored modules, 5787 lines of comment-dense source, minified into the twins the gem actually ships.

| Module | Role | Pinned |
|---|---|---|
| `reactive_controller.js` | the ONE generic Stimulus controller plus the custom turbo-stream actions | `preload: true` |
| `confirm.js` | the overridable confirm resolver (`setConfirmResolver`) | `preload: true` |
| `confirm_predicate.js` | the conditional-confirm predicate registry (`setConfirmPredicate`) | `preload: true` |
| `compute.js` | the client-side reducer registry (`setComputeReducer`) | `preload: true` |
| `inspect.js` | the on-demand console inspector | `preload: false` — a debugging tool nobody should pay for |

## The build

`rake build:js` runs `scripts/build_client.js`, which minifies each entry ON ITS OWN with `sourcemap: "linked"` and the four cross-module specifiers kept EXTERNAL. Per-file, never a bundle: the modules are pinned separately so an app can override the `confirm`/`compute`/`confirm_predicate` seams, and bundling would inline them and break every override. The output is deterministic (bun derives the sourcemap debugId from content), which is what lets the `.min.js`/`.map` be checked in and `rake build:js_check` gate CI on `git diff --exit-code` — with the pathspec QUOTED so git expands it against the index, or deleting a module would slip past the guard.

A source edit is therefore a THREE-file change: the source, the rebuilt `.min.js` + `.map`, and the re-synced `spec/dummy/public/vendor/<name>.js`. Two guards enforce it: `rake build:js_check` and `spec/phlex/vendored_controller_sync_spec.rb`, whose failure message prints the exact re-sync command. The vendored copies are byte-identical to the MINIFIED builds on purpose — production ships minified, so the browser suite must exercise minified code or a minifier-induced bug (a mangled name breaking a lifecycle hook, a dropped export) ships untested.

## Imports are bare specifiers, never relative

`reactive_controller.js` imports `"phlex/reactive/confirm"`, not `"./confirm.js"`. Under importmap-rails + Propshaft the controller is served at its DIGESTED url; Propshaft rewrites only `RAILS_ASSET_URL(...)` and the import map resolves only BARE specifiers, so a relative sibling import would resolve to an undigested `/assets/…/confirm.js` that 404s — and a throwing import takes down every Stimulus controller on the page. The engine's `importmap.pin` calls are what make the bare specifier resolve; `tsconfig.json` `paths` make bun resolve it the same way for the tests.

## The wire

`POST <action path>` with a turbo-stream `Accept`, body `{ token, act, params }` as JSON — or the SAME payload as multipart `FormData` (token/act flat, params bracketed, files appended) when the root holds a chosen `<input type="file">`. Only the encoding differs. `act`, not `action`: `action` is a reserved Rails routing param. The response is a `<turbo-stream>` Turbo applies by the component's id.

## Custom turbo-stream actions

Registered once on `window.Turbo.StreamActions` (never an `@hotwired/turbo` named import — unreliable under importmap/esbuild), each registration idempotent:

| Action | What it does |
|---|---|
| `reactive:visit` | `Turbo.visit(url)` — a 200-carried redirect, so `response.redirected` still catches real auth/CSRF redirects |
| `reactive:token` | writes the fresh token onto the root as a pure attribute set — a focused input and its caret survive |
| `reactive:js` | runs the server's op chain through the same allowlist interpreter `on_client` uses (unknown op → warn and skip) |
| `reactive:defer` | the delivery directive: `via="fetch"` POSTs the token, `via="stream"` mounts a `<pgbus-stream-source>`, with supersession per target id |

Plus the document-level wrappers `registerReactiveDismiss` (any `[data-reactive-dismiss-after]` self-removes), `registerReactiveEffects` (wraps element stream renders in the enter/exit/update choreography), `registerReactiveOffline` and `registerReactiveActions`.

## Controller invariants

- **The root's `id` must equal `component.id`.** The client self-matches its next token by `this.element.id`; an empty id makes `#extractToken` fall back to the FIRST token in the response — a child's — and the next action POSTs a foreign token to a silent 403. `connect()` warns on an empty id so the failure surfaces on page load, not on click 2.
- **The trigger is `event.currentTarget`, not `event.target`.** A `<button><span>Save</span></button>` click has `target === span`, which carries no params.
- **`preventDefault()` runs synchronously in the event handler**, before any async confirm resolver — once awaited it is too late and a `submit` trigger natively POSTs and navigates. Window-bound triggers are exempt (they hear every matching event on the page), and so is a `checked: :keep` optimistic hint, which exists precisely to let the native flip happen.
- **Behaviour is decided from `event.params`**, never by sniffing the Stimulus descriptor.
- **Feature gates are decided once at `connect()`**, and each gate wires its `turbo:morph-element` listener only when the component actually uses the feature — a component that never uses `reactive_lazy`, dirty tracking, show bindings, filters, tags, nested JSON rows, compute seeding or the clipboard gate pays for no listener at all. Every bound handler is held on a private field so `disconnect()` removes exactly it.
- **State that must survive re-renders belongs in a signed action.** Client ops are ephemeral UI: any server re-render rebuilds from server state and resets what they toggled.
- **A gate that HIDES a dead control must consider the root itself**, not only descendants — a button-only component mixes `on_client` onto `reactive_root`, so the root can be the trigger (see `../review/client-runtime.md`).

## The overridable seams

`setConfirmResolver` (async confirm UI), `setConfirmPredicate` (multi-field conditional confirm), `setComputeReducer` (named client-side reducers behind `reactive_compute`). Each lives in its own pinned module so an app's `import { setX } from "phlex/reactive/…"` and the controller's own import resolve to the same instance.

Related: `../component/summary.md` (the Ruby half of every binding), `../testing-and-ci/summary.md` (the bun suite and the browser matrix).
