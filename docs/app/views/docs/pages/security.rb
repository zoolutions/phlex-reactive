# frozen_string_literal: true

module Views
  module Docs
    module Pages
      class Security < DocsUI::Page
        title 'Security & threat model'
        eyebrow 'Guide'
        description 'Secure phlex-reactive Rails actions: signed-identity tokens, default-deny actions, schema-coerced params, authorization, CSRF, and endpoint failure modes'

        def lead
          'Every reactive action is a browser-reachable RPC. phlex-reactive makes the safe path the ' \
            'default, but you own the authorization boundary. Read this once.'
        end

        def content
          signature_guarantees
          authorize_rule
          verify_authorized_rule
          default_deny_rule
          params_rule
          secrets_rule
          csrf_auth
          two_seams
          failure_modes
          failure_ux
          error_flash_ux
          token_lifetime
          client_drafts
          checklist
        end

        private

        def signature_guarantees
          DocsUI::Section("What the signature guarantees (and what it doesn't)") do
            render Components::Diagrams::TrustBoundary.new
            md <<~MD
              The DOM token is a `MessageVerifier`-signed payload:

              - **Record-backed:** `{ "c" => "Todos::Item", "gid" => "gid://app/Todo/42" }`
              - **State-backed:** `{ "c" => "Counter", "s" => { "count" => 3 } }`
              - **Record + state:** `{ "c" => "Fields::InlineEdit", "gid" => "gid://app/User/7", "s" => { "attribute" => "name", "editing" => true } }`

              When a component declares both `reactive_record` and `reactive_state`, the
              record's GlobalID and the declared state are signed into **one** payload — so
              the transient mode (e.g. which column an inline edit may write) is tamper-proof
              alongside the record.

              **Guarantees** (tampering any of these fails verification → HTTP 400):

              - The component class can't be swapped (can't point a `Todo` token at an
                `AdminUser` component).
              - The record's GlobalID can't be swapped or forged.
              - State values can't be edited — including state signed alongside a record (the
                client can't switch an inline edit's `attribute` to a column it shouldn't touch).

              **Does NOT guarantee**: that **this user** may act on this record. The signature
              proves the token is one **we** minted, not that the current session is allowed to
              mutate the target. **You must authorize.**
            MD
            # Dogfood: a reactive modal shows what the token actually contains.
            render ReactiveModalComponent.new(modal: 'signed-identity', label: "What's in the token?")
          end
        end

        def authorize_rule
          DocsUI::Section('Rule 1 — authorize inside every mutating action') do
            DocsUI::Code(<<~RUBY, lexer: :ruby)
              def rename(title:)
                authorize! @todo, :update?      # Pundit / ActionPolicy / your check
                @todo.update!(title:)
              end
            RUBY
            md <<~MD
              Register your authorizer's exception so it renders as 403:
            MD
            DocsUI::Code(<<~RUBY, lexer: :ruby, filename: 'config/initializers/phlex_reactive.rb')
              Phlex::Reactive.authorization_errors = [Pundit::NotAuthorizedError]
              # or [ActionPolicy::Unauthorized]
            RUBY
            md <<~MD
              A useful discipline: **treat an action without an authorize! as a bug** unless
              it's provably harmless (a view-mode toggle on already-visible data). Consider a
              RuboCop rule or a code-review checklist for `action`-declared methods.
            MD
          end
        end

        def verify_authorized_rule
          DocsUI::Section('verify_authorized — the fail-closed enforcement of Rule 1') do
            md <<~MD
              Rule 1 is a discipline; **`verify_authorized` enforces it at runtime**,
              ON by default. An action that completes **without any authorization
              call** raises `Phlex::Reactive::AuthorizationNotVerified` **inside the
              transaction** — so the mutation **rolls back** (fail-closed, stronger
              than Pundit's after-the-fact check, which runs post-commit). A
              forgotten `authorize!` becomes a loud 500 your error tracker sees, not
              a silent hole.

              It detects a call to any configured authorization method **or**
              `mark_authorized!`, made anywhere during the action (a helper the
              action calls counts). Three ways to satisfy it:
            MD
            DocsUI::Code(<<~RUBY, lexer: :ruby)
              def rename(title:)
                authorize! @todo, :update?   # 1. an authorization method (detected)
                @todo.update!(title:)
              end

              def publish
                raise NotAllowed unless @post.author == Current.user
                mark_authorized!             # 2. a bespoke check the interceptor can't see
                @post.update!(published: true)
              end

              skip_verify_authorized          # 3. a genuinely public component/action
            RUBY
            md <<~MD
              Match the method names to your library, or disable the guard (not
              recommended — you lose the fail-closed net). See the **Debugging &
              tooling** guide for the full workflow.
            MD
            DocsUI::Code(<<~RUBY, lexer: :ruby, filename: 'config/initializers/phlex_reactive.rb')
              Phlex::Reactive.authorization_methods = %i[authorize! authorize allowed_to?]
              # Phlex::Reactive.verify_authorized = false
            RUBY
          end
        end

        def default_deny_rule
          DocsUI::Section('Rule 2 — actions are default-deny, keep it that way') do
            md <<~MD
              Only methods declared with `action :name` are invokable. Don't declare an action
              you don't intend to expose. Public methods without `action` are unreachable, but
              don't rely on obscurity — declare narrowly.

              The **client-op vocabulary** carries the same posture: a fixed frozen whitelist
              (unknown ops warn-and-skip), an attribute allowlist enforced twice (build time
              AND interpret time), and an **actor-only tier** — `focus`, `focus_first`,
              `submit` (#226), and `paste_into` (#228) are allowed from the actor's own
              gesture or reply (`on_client` / `reply.js` / a reducer's `$ops` — though the
              reducer builder deliberately omits `paste_into`) but **refused in
              broadcasts**: a broadcast op must never steal focus in, force-submit a form
              from, or read the clipboard of, every subscriber's tab.
            MD
          end
        end

        def params_rule
          DocsUI::Section('Rule 3 — params are schema-coerced, declare them') do
            DocsUI::Code(<<~RUBY, lexer: :ruby)
              action :rename, params: { title: :string }
              def rename(title:) = @todo.update!(title:)   # only `title`, cast to String
            RUBY
            md <<~MD
              Anything not in the schema is dropped before reaching your method, so a malicious
              `{ admin: true, title: "x" }` body can't mass-assign. Never do
              `@record.update!(params)` — take explicit, declared params.

              The schema is compiled once at declaration: a typo'd type symbol raises
              `Phlex::Reactive::UnknownParamType` at class load rather than silently coercing to
              a string at click time. A declared value that can't be coerced to its type (a bad
              `:date`/`:decimal`, a non-file for `:file`) is dropped — never fabricated — so the
              action sees its keyword default, not a bogus value.
            MD
            custom_param_types
            DocsUI::Callout(:note, title: 'File params (:file / [:file])') do
              plain 'A reactive action can accept an uploaded file (the client switches to multipart FormData when ' \
                    'a file input is present). The multipart request runs through the same gates as a JSON one — ' \
                    'the signed identity is still verified, the action is still default-deny, and the file is still ' \
                    'schema-coerced: a :file param accepts only an actual uploaded file and is dropped for any ' \
                    'non-file value (a forged string can\'t fabricate a file). Apply your own attachment rules in ' \
                    'the action (content-type/size allow-lists, authorize! before attaching) exactly as you would ' \
                    'in a plain controller — the schema proves the value is a file, not that this user may upload it.'
            end
          end
        end

        def custom_param_types
          md <<~MD
            **Custom validators are a dropping type (`Phlex::Reactive.param_type`).** The
            built-in coercions aren't the whole surface — you can register your own typed
            validator in an initializer. The block receives the raw client value and returns
            the coerced value, or `Phlex::Reactive::ParamSchema::DROP` to **reject** it. A
            drop keeps the exact same contract as a built-in: the keyword default applies, so
            a rejected value is never fabricated — it's simply absent.
          MD
          DocsUI::Code(<<~RUBY, lexer: :ruby, filename: 'config/initializers/phlex_reactive.rb')
            Phlex::Reactive.param_type(:money) do |value|
              /\\A\\d+(\\.\\d{1,2})?\\z/.match?(value.to_s) ? BigDecimal(value) : Phlex::Reactive::ParamSchema::DROP
            end

            # then, in any component — validated at declaration like any built-in:
            action :charge, params: { amount: :money }
            def charge(amount:) = @invoice.charge!(amount)   # a BigDecimal, or unset if rejected
          RUBY
          md <<~MD
            This makes the schema a **validation** boundary, not just a coercion one: a
            security-relevant rule (a currency shape, an allow-listed enum, a bounded integer)
            lives in the type and rejects a bad value with `DROP` before it reaches your
            method. `DROP` is a **public** sentinel exactly so custom types can use it. The
            registry is **frozen after boot** — register during initialization only; a runtime
            `param_type` call raises.
          MD
        end

        def secrets_rule
          DocsUI::Section("Rule 4 — don't put secrets in state-backed tokens") do
            md <<~MD
              State-backed tokens are **signed** (tamper-proof) but **not encrypted** — the
              values are readable in the DOM (base64). Don't sign secrets into `reactive_state`.
              For anything sensitive, use `reactive_record` (only the GlobalID is exposed) and
              read the sensitive data server-side.
            MD
          end
        end

        def csrf_auth
          DocsUI::Section('CSRF and authentication') do
            md <<~MD
              The action endpoint inherits from `Phlex::Reactive.base_controller_name` (default
              `ActionController::Base`). For a real app:
            MD
            DocsUI::Code(<<~RUBY, lexer: :ruby)
              Phlex::Reactive.base_controller_name = "ApplicationController"
            RUBY
            md <<~MD
              This gives you CSRF protection (the client sends `X-CSRF-Token`) and your auth
              filters. **Caveat**: if you have **public** reactive components (e.g. on a
              logged-out page) and your `ApplicationController` force-redirects unauthenticated
              requests to a login page, the action POST will be redirected and silently fail.
              Either:

              - `skip_before_action :authenticate` for the action endpoint (subclass it), or
              - keep public components state-backed and authorize per-action where it matters.
            MD
          end
        end

        def two_seams
          DocsUI::Section('Two seams: HTTP-layer vs component-layer') do
            md <<~MD
              There are **two** places to wrap a reactive action, and they see different things.
              Reach for the one that matches your concern:

              | | Base controller (`base_controller_name`) | `Phlex::Reactive.around_action` |
              |---|---|---|
              | **Layer** | HTTP request | the resolved component action |
              | **Sees** | headers, session, `request` | the component instance, action name, **coerced** params, `request` |
              | **Runs** | full Rails filter chain | inside `with_connection_id`, **outside** the transaction |
              | **Use for** | auth, CSRF, coarse per-IP rate limiting | audit logging, component-aware rate limiting, assertions |

              Plain Rails `around_action` / `rate_limit` on a dedicated base controller already
              covers attributes, authentication, and coarse per-IP throttling. What that layer
              **cannot** see is the resolved component, the declared action name, or the coerced
              params — and it can't position itself *inside* the connection-id scope but *outside*
              the action's transaction. `Phlex::Reactive.around_action` is that component-aware seam:
            MD
            DocsUI::Code(<<~'RUBY', lexer: :ruby)
              # config/initializers/phlex_reactive.rb
              Phlex::Reactive.around_action do |ctx, &action|
                Rails.logger.tagged("reactive", "#{ctx.component.class}##{ctx.action_name}") do
                  # A rate-limit rejection here NEVER opens a transaction (this seam
                  # sits outside transaction_wrapper). Raise a registered error -> 403.
                  RateLimiter.check!(ctx.request.remote_ip, ctx.action_name)

                  result = action.call
                  AuditLog.record!(actor: Current.user, action: ctx.action_name)
                  result   # <- REQUIRED: return the continuation's value (see below)
                end
              end
            RUBY
            md <<~MD
              `ctx` is a frozen `Phlex::Reactive::ActionContext` — `component`, `action_name`,
              `params` (already **schema-coerced**; dropped keys are gone), and `request`. The
              fold sits **after** token verify, component resolution, default-deny, and param
              coercion, so a wrapper can never widen what's invokable.

              **The one contract that bites: each wrapper MUST return `action.call`'s value.** The
              endpoint type-checks the action's return for a `Phlex::Reactive::Response`
              (`replace` / `remove` / `redirect` / …); a wrapper that ends on its logger's return
              value instead silently downgrades **every** reply to the implicit self-replace. Name
              the result and return it, as above.

              A wrapper raising an error registered in `Phlex::Reactive.authorization_errors`
              renders as **403** (with the same diagnostics as an in-action `authorize!`);
              an unregistered raise is a **500**, exactly as today. Multiple wrappers nest in
              registration order — the last-registered runs outermost. Tests reset the stack with
              `Phlex::Reactive.reset_around_actions!`.
            MD
          end
        end

        def failure_modes
          DocsUI::Section("The endpoint's failure modes") do
            md <<~MD
              - Tampered / forged / expired token → `400 Bad Request` (`kind: :tampered`)
              - Token class no longer resolves → `400 Bad Request` (`kind: :unknown_class`)
              - Token class resolves but isn't a reactive component → `400 Bad Request` (`kind: :not_reactive_class`)
              - Undeclared action → `403 Forbidden` (`kind: :forbidden`)
              - `authorize!` raised (registered error) → `403 Forbidden` (`kind: :forbidden`)
              - Record GlobalID no longer resolves → `404 Not Found` (`kind: :not_found`)
              - `GET /reactive/fragment/:id` for a component that did not declare
                `reactive_lazy cache:` → `404 Not Found` (`kind: :not_found`); every reply of
                that endpoint other than the 200 and its 304 revalidation is
                `Cache-Control: no-store` — see
                [Deferred rendering](/docs/deferred-rendering)

              The two 400s share a status but carry **distinct diagnostics**: `:unknown_class`
              (the token's class no longer constantizes — a component renamed/removed while a
              page was open) vs `:not_reactive_class` (it resolves but doesn't
              `include Phlex::Reactive::Component`). The `verbose_errors` body and the
              `error_flash` kind differ between them, so you can tell one from the other.

              The client runtime logs non-OK responses, applies no DOM change, and dispatches a
              `reactive:error` lifecycle event so your UI can react — see below.

              Every failure is warn-logged as `[phlex-reactive] …` in every environment. With
              `Phlex::Reactive.verbose_errors` on (the default in development and test via
              `Rails.env.local?`; off in production), the response also carries a plain-text
              diagnostic body — the client prints it via `console.error` — saying which failure
              this was: a tampered/stale token, a token class that no longer resolves (or one
              that isn't reactive), an undeclared action (listing the declared ones), a
              registered authorization error, or a GlobalID that no longer finds its record.
              Param coercion additionally logs every dropped key with its full bracketed path
              and reason (undeclared / uncoercible), with a hint when a flat name looks like the
              bracketed twin of a declared nested key. The flag never changes a status — only
              the body and the logs.
            MD
          end
        end

        def failure_ux
          DocsUI::Section('Failure UX — the lifecycle events') do
            md <<~MD
              The generic controller dispatches three bubbling, composed `CustomEvent`s around
              every action round trip, so an app can toast an error, veto a dispatch, instrument
              latency, or build retry UI without forking the controller:

              - `reactive:before-dispatch` — cancelable, fired before debounce/enqueue with
                `{ action, params, element }`. `event.preventDefault()` skips the round trip
                entirely (nothing is scheduled).
              - `reactive:applied` — fired with `{ action, params, html }` once the streams were
                handed to `Turbo.renderStreamMessage` (Turbo applies them asynchronously — for
                post-morph timing listen to Turbo's own events).
              - `reactive:error` — fired in every failure branch with
                `{ action, params, kind, status?, body?, retry? }`; `kind` is one of
                `redirected | http | content-type | timeout | offline | network` (all retriable)
                or `apply` — the server already completed the mutation but something AFTER the
                fetch threw inside the controller itself (a malformed response, a Turbo render
                error); it carries NO `retry`, since retrying would re-POST an action that
                already succeeded. A throwing `reactive:applied` LISTENER is different — the DOM
                spec never propagates a listener's exception back to `dispatchEvent`'s caller, so
                it can't surface as `reactive:error` at all; it just logs. `retry()` (when
                present) re-enters the request queue with the freshest token and freshly
                collected fields (and no-ops once the component left the DOM).
            MD
            DocsUI::Code(<<~JAVASCRIPT, lexer: :javascript)
              // A page-level toaster: one listener, or plain Stimulus composition —
              // <body data-controller="toast" data-action="reactive:error->toast#show">
              document.addEventListener("reactive:error", ({ detail }) => {
                toast(`Action failed (${detail.kind}${detail.status ? ` ${detail.status}` : ""})`, {
                  onRetry: detail.retry, // re-enqueues with the freshest signed token
                })
              })
            JAVASCRIPT
            DocsUI::Callout(:note, title: 'The events are hooks, not the security boundary') do
              plain 'A 403 still denies the action server-side whether or not anything listens; the existing ' \
                    'console.error logging is unchanged. The events only make the failure visible to your UI.'
            end
            md <<~MD
              The `timeout` and `offline` kinds bound the request itself. `AbortSignal.timeout`
              (default 30s, set `<meta name="phlex-reactive-timeout">`) aborts a hung request so
              one dead connection can no longer wedge the component's request queue; an offline
              click short-circuits BEFORE the fetch (the edit is never half-sent) and mirrors
              `data-reactive-offline` onto `<html>` as a pure CSS hook.
            MD
            DocsUI::Callout(:warning, title: 'A timed-out request may have SUCCEEDED — no auto-replay') do
              plain 'A timeout means the server did not answer in time, NOT that it did nothing — the mutation ' \
                    'may have committed. phlex-reactive never auto-replays, and even a manual retry() can ' \
                    'double-apply a non-idempotent action. Make retryable actions idempotent, or gate retry UI.'
            end
          end
        end

        def error_flash_ux
          DocsUI::Section('Showing the user a failure (error_flash, error bodies, dismiss_after)') do
            md <<~MD
              The lifecycle events are the hook; these three built-ins are the ready-made
              surface, all opt-in and **status-preserving** — no flag ever changes an HTTP
              status.

              - **In-action validation replies** — a failure the action knows about returns a
                flash at 200: `reply.replace.flash(:error, "Title can't be blank")`.
              - `Phlex::Reactive.error_flash` — a `->(kind) { "message" }` lambda. When set,
                every endpoint rescue path (400/403/404) renders a turbo-stream flash the user
                sees, at the SAME status. It composes with `verbose_errors` (the flash wins the
                body, the diagnostic still logs) and degrades gracefully if the lambda raises
                (falls back to the bare/diagnostic body — never a 500).
              - **Non-OK turbo-stream bodies are rendered** — the client applies a turbo-stream
                error body instead of discarding it, and marks the root
                `data-reactive-error="<kind>"` (styleable in pure CSS), cleared on the next
                success.
              - `dismiss_after:` on `reply.flash` — a document-level handler removes the flash
                after the timeout, so it self-cleans reply AND broadcast flashes.

              **The exact `kind` symbols the lambda receives** are the endpoint's server-side
              failure kinds — the same ones on the `reactive_error` path — so a complete mapping
              branches on all five:

              - `:tampered` — the token failed verification (a 400).
              - `:unknown_class` — the token's component class no longer resolves (a 400).
              - `:not_reactive_class` — it resolves but isn't a reactive component (a 400).
              - `:forbidden` — an undeclared action, or a registered `authorize!` error (a 403).
              - `:not_found` — the record's GlobalID no longer finds its row (a 404).
            MD
            DocsUI::Code(<<~RUBY, lexer: :ruby)
              # config/initializers/phlex_reactive.rb
              Phlex::Reactive.error_flash = ->(kind) do
                case kind
                when :not_found                                then "That item is no longer available."
                when :forbidden                                then "You don't have permission to do that."
                when :tampered, :unknown_class, :not_reactive_class
                  "This page is out of date — please refresh."
                else                                                "Something went wrong — please try again."
                end
              end

              # In an action, a self-dismissing validation flash:
              reply.replace.flash(:error, "Couldn't save — try again", dismiss_after: 4000)
            RUBY
            DocsUI::Callout(:note, title: 'A 400 error body never refreshes the held token') do
              plain 'The identity token is not a nonce — it stays retry-valid. The client only adopts a fresh ' \
                    'token from a body that re-renders THIS element\'s id, so an error/foreign body can\'t swap ' \
                    'the token out. This is intentional; do not "fix" it.'
            end
          end
        end

        def token_lifetime
          DocsUI::Section('Token lifetime & rotation') do
            md <<~MD
              Tokens are signed with `secret_key_base` (or your `Phlex::Reactive.verifier`).
              They **don't expire** — the signing path (`Phlex::Reactive.sign` →
              `verifier.generate(payload, purpose:)`) threads no `expires_in`/`expires_at`, and
              `expires_in` is a per-message `generate` option, not a verifier-level setting. So
              swapping in a custom `MessageVerifier` alone **won't** impose expiry.

              If you need expiry, **include a server-checked timestamp in the signed state** and
              reject a stale one inside the action — e.g. sign `issued_at` into `reactive_state`
              and compare it to `Time.current` before mutating. That puts the freshness check
              where the action already runs, at the same authorization boundary you own.

              Rotating `secret_key_base` (or your verifier's secret) invalidates all outstanding
              tokens at once — open tabs must reload.

              The signed payload is **versioned** (a `"v"` key, currently
              `Phlex::Reactive::TOKEN_VERSION`). This lets a future change to the token shape
              **upgrade tokens already in flight** instead of breaking every open page at deploy:
              verification runs the payload through an upgrader chain (oldest → current) before
              your component rebuilds from it. A token minted before versioning existed carries no
              `"v"` and is read as-is — introducing versioning invalidated nothing.
            MD

            DocsUI::Callout(:note, title: 'Unknown token versions fail closed') do
              md <<~MD
                A token signed by a **newer** deploy than the running code (a rollback scenario)
                verifies its signature but carries a version this code doesn't understand. Rather
                than guess the newer shape, `Phlex::Reactive.verify` returns `nil`, so the endpoint
                answers 400 — the same path as a tampered token. Fail-closed, never fail-open.
              MD
            end
          end
        end

        def client_drafts
          DocsUI::Section('Client-only drafts (reactive_persist) — what lives in localStorage') do
            md <<~MD
              `reactive_persist` (#239) keeps a draft of a root's owned field
              values in **this browser's `localStorage`**. It is client-only in
              the same sense as `reactive_show`: nothing leaves the browser, no
              token is minted, no endpoint is touched. What the threat model
              *does* cover:

              - **phlex-reactive never writes markup.** A draft is replayed via
                `.value` / `.checked` / `.selected`; a bare `[contenteditable]`
                via `textContent`; a rich editor (`lexxy-editor`, `trix-editor` —
                #241) through its **own** `value` setter, which is the editor's
                sanitizing import path (Trix `HTMLParser`, Lexxy
                `$generateNodesFromDOM` + sanitizer) — the same path a paste or
                the server-rendered value takes. Never `innerHTML`. A tampered
                draft can only produce what the user could type or paste into
                that field, and the server still validates the submit exactly as
                if they had.
              - **PII sits on disk for `ttl`.** Default 7 days; an expired draft
                is removed on read, a successful submit clears it. On a shared
                computer `ttl` + the submit-clear are the mitigation — shorten
                `ttl:` for sensitive forms.
              - **Secrets are excluded by default** — `type=password`, `hidden`
                and `file` controls never reach storage. **Honeypots are not
                detectable**: an invisible-captcha text input looks like any
                other field, so mark it `reactive_persist_skip` (or render it
                outside the root). `autocomplete="off"` is deliberately *not* an
                implicit skip.
              - **The draft ops are actor-only.** `js.persist_state` /
                `js.persist_clear` are allowed from `on_client`, `reply.js` and
                `reactive_on_complete`, and **refused** by `broadcast_to(js:)` —
                a broadcast that rewrote or wiped every subscriber's draft would
                be hostile.
              - **Storage failure is not an error.** A private window, a quota
                error or blocked storage degrades to "no draft"; the only
                diagnostic is a `console.info` under `Phlex::Reactive.debug`.
            MD
          end
        end

        def checklist
          DocsUI::Section('Quick checklist') do
            md <<~MD
              - Every mutating action calls `authorize!` (or is provably harmless).
              - `Phlex::Reactive.authorization_errors` includes your authorizer's error.
              - Every action with input declares a `params:` schema.
              - No `@record.update!(params)` — only declared params.
              - No secrets in `reactive_state`; sensitive data uses `reactive_record`.
              - `base_controller_name` set to `ApplicationController` (CSRF + auth).
              - Public components don't get redirected to login on the action POST.
            MD
          end
        end
      end
    end
  end
end
