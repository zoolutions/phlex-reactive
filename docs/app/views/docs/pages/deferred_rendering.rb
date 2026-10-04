# frozen_string_literal: true

module Views
  module Docs
    module Pages
      class DeferredRendering < DocsUI::Page
        title 'Deferred rendering'
        eyebrow 'Guide'
        description 'Defer expensive reply segments in reactive Phlex components with reply.defer and reactive_lazy: placeholder now, the real render streams to the actor when ready'

        def lead
          "Take a genuinely expensive reply segment off the actor's critical path — " \
            'the reply returns instantly with a pending marker, and the real render ' \
            'streams to the same actor when ready. Plus `reactive_lazy` for a lazy ' \
            'initial mount.'
        end

        def content
          profile_first
          the_trade
          the_api
          placeholders
          semantics
          delivery
          failure
          lazy_mount
          lazy_on
          security
          config_reference
        end

        private

        def profile_first
          DocsUI::Section('Profile first — defer is not a performance fix') do
            DocsUI::Callout(:warning) do
              md <<~MD
                **An app-side N+1 or a missing eager-load will look exactly like
                framework lag.** Fix the synchronous path first; reach for `defer`
                only when a segment is *genuinely* expensive.
              MD
            end
            md <<~MD
              The origin story of this feature is the cautionary tale. A live
              scoreboard re-rendered inside every debounced keystroke and felt slow —
              it looked like the framework couldn't keep up. The real cause was an
              app-side N+1 — **2+N queries per keystroke** — fixed with a one-line
              eager load. No gem change needed, and no `defer` either.

              So before you defer anything, look at the log (or your APM's
              `render.phlex_reactive` events) for the queries the segment runs. A
              rollup that's slow because it *loads* wrong should be fixed, not hidden
              behind a shimmer. `defer` is for the segment that stays expensive after
              the queries are right — a cross-aggregate rollup, an external-API
              summary, a render that is simply big.
            MD
          end
        end

        def the_trade
          DocsUI::Section('The honest trade') do
            md <<~MD
              Every reply segment normally renders synchronously on the request
              thread, so one expensive segment stalls the actor's **whole**
              interaction — the cheap parts of the reply wait for the slow one.

              `reply.defer` trades slightly **worse time-to-full-content** (one extra
              round trip) for much **better actor reply latency**. It moves cost off
              the critical path; it never removes it:

              - **Actor reply latency** — better. The reply returns as soon as the
                cheap streams render; typing and clicking stay responsive.
              - **Time-to-full-content** — slightly worse. The deferred segment
                arrives after its own render plus one extra hop.

              If both metrics matter equally to the interaction, defer buys you
              nothing — render synchronously and keep the simpler wire.
            MD
          end
        end

        def the_api
          DocsUI::Section('reply.defer') do
            md <<~MD
              Chain `.defer(component)` onto any reply. The canonical shape — a set
              logger whose cheap volume cell updates instantly while the
              cross-aggregate session totals render off the critical path:

              ```ruby
              action :update, params: { weight_kg: :float, reps: :integer, rpe: :float }

              def update(weight_kg:, reps:, rpe:)
                @set.update!(weight_kg:, reps:, rpe:)
                reply
                  .streams(volume_cell_stream)                 # instant, cheap
                  .defer(SessionTotals.new(workout: @workout)) # off the critical path
              end
              ```

              The deferred component must be a reactive component — its **signed
              identity** is what the deferred render is rebuilt from, never its
              state. A bare `reply.defer(component)` with no prior verb keeps the
              default self-replace; the deferred segment rides alongside.

              **Keep-content is the default.** While the deferred render is pending,
              the target keeps its current (stale) content and carries
              `data-reactive-defer-pending` plus `aria-busy="true"`. Style the wait
              with pure CSS:

              ```css
              [data-reactive-defer-pending] { opacity: .5; }
              ```
            MD
          end
        end

        def placeholders
          DocsUI::Section('Placeholders and morph arrivals') do
            md <<~MD
              ```ruby
              reply.defer(comp)                             # keep-content default (mark pending)
              reply.defer(comp, placeholder: true)          # comp's deferred_placeholder, or a built-in shell
              reply.defer(comp, placeholder: Skeleton.new)  # explicit skeleton (component or String)
              reply.defer(comp, morph: true)                # arrival morphs instead of replacing
              ```

              `placeholder:` opts into a skeleton that **replaces** the target
              immediately: a shell `<div>` that owns the component's id and carries
              the pending markers plus a `reactive-defer-placeholder` class.

              - `placeholder: true` asks the component — its `deferred_placeholder`
                method supplies the shell's content. It may return a **Phlex
                component instance** (rendered), an **`html_safe` String**
                (intentional markup, passed verbatim), or a **plain String** (escaped
                as data — text, not markup). No method (or `nil`) means the bare
                built-in shell, which the CSS class is there to style.
              - `placeholder: <component-or-string>` supplies the skeleton inline,
                under the same content contract.

              `morph: true` makes the **arrival** morph in place instead of replacing
              — use it when the deferred target holds focusable inputs. The mode
              rides *inside* the signed token, so the client can't flip it.
            MD
          end
        end

        def semantics
          DocsUI::Section('Semantics: transactional, actor-scoped, superseding') do
            md <<~MD
              - **Transactional.** The defer directive rides the reply, which renders
                only after the action's transaction **committed**. A rollback (or a
                denied action) takes the error path and emits **no** directive — a
                deferred render can never leak a change that didn't happen.
              - **Actor-scoped.** The deferred render reaches only the acting user;
                it is never echoed to peers. Cross-tab updates keep going through
                `broadcast_to`, exactly as before.
              - **Superseding.** A newer action for the same target aborts the
                in-flight deferred render (the fetch is aborted, the one-shot stream
                unsubscribed). A fast typist never gets stale totals painted over
                fresh ones.
              - **Arrival is interactive.** The deferred HTML carries a fresh signed
                action token, so the component lands ready for its next action — no
                dead controls, no re-mount.
            MD
          end
        end

        def delivery
          DocsUI::Section('Delivery: two lanes, one API') do
            md <<~MD
              How the deferred render reaches the actor is a transport decision, not
              an API one — the Ruby you write is identical on both lanes.
              `Phlex::Reactive.defer_transport` picks:

              | Value | Behavior |
              |---|---|
              | `:auto` (default) | Push **iff** fully capable — pgbus reactive Streams **+** `SignedName` **+** ActiveJob present — else pull. |
              | `:fetch` | Always pull. |
              | `:stream` | Request push; **degrades to pull with a one-time warning** when the capability is absent. Degrade, never break. |

              **Pull (`fetch`) — the universal lane.** The directive carries a
              purpose-scoped, short-TTL signed token; the client POSTs it to
              `POST /reactive/defer` **in parallel**, off the per-component action
              queue, and applies the rendered stream when it lands. It's just HTTP —
              it works on every transport, including plain Action Cable.

              **Push (`stream`) — the pgbus lane.** The reply mints a durable
              one-shot pgbus stream (a `prdefer_<hex>` key), enqueues a
              `Phlex::Reactive::DeferredRenderJob` (queue: `defer_job_queue`, default
              `"default"`), and hands the client a signed SSE `src`. The job renders
              off the request thread and broadcasts **durably**; `since-id="0"`
              replays the one message even when the broadcast beat the client's
              subscription — the broadcast-before-subscribe race is closed by
              construction. The broadcast's payload ends by removing the client's own
              source element, so the subscription tears itself down with the content
              it delivered.

              Capability is probed **live** at reply time via
              `Phlex::Reactive.defer_push_capable?` — a runtime capability gate, not
              a version check — so removing pgbus (or ActiveJob) silently falls back
              to pull. And if the push lane fails mid-reply (signing, enqueue), the
              segment degrades to a fetch directive rather than 500ing a reply whose
              mutation already committed.
            MD
            DocsUI::Callout(:tip) do
              md <<~MD
                Point `defer_job_queue` at a **fast** queue in production. A deferred
                segment is a UX-latency render; letting it starve behind heavy jobs
                defeats the point.
              MD
            end
          end
        end

        def failure
          DocsUI::Section('Failure handling') do
            md <<~MD
              The shimmer must never lie, and it must never hang:

              - **Fetch failure / timeout** — the pending markers are cleared, the
                target gets `data-reactive-error="defer"` (style it in CSS), and a
                bubbling `reactive:error` event fires with `kind: "defer"` and a
                `retry()` function that re-enters the fetch with the same token
                (still valid inside the TTL).
              - **`render?` false** — the defer endpoint returns **204**: pending
                cleared, current content kept. Nothing to render is not an error.
              - **Gone record (push lane)** — a record deleted while the job sat in
                the queue broadcasts the *cleanup* instead: pending markers cleared,
                subscription torn down. No retry — there is nothing to render.
            MD
          end
        end

        def lazy_mount
          DocsUI::Section('Lazy initial mount (reactive_lazy)') do
            md <<~MD
              The same machinery covers the *initial* mount — Livewire's `#[Lazy]`
              shape. Declare `reactive_lazy` and the first (page-embedded) render
              ships only a placeholder shell: the root id, the generic controller,
              the pending markers, and a defer token **on the root**. The client's
              `connect()` probes the token and fetches the real content through the
              same pull path a reply directive uses:

              ```ruby
              class SessionTotals < ApplicationComponent
                include Phlex::Reactive::Component
                reactive_record :workout
                reactive_lazy                    # first render = placeholder shell + fetch on connect

                def deferred_placeholder = TotalsSkeleton.new   # optional
              end
              ```

              Lazy applies **only** to the page-embedded initial mount. Every render
              that goes through the reactive machinery — an action reply's
              self-replace, a broadcast, the defer endpoint or job — renders the
              **real** template, so an action on a lazy component never costs two
              round trips.

              Lazy mount is pull-only: a page render has no transaction to defer
              behind, and enqueueing jobs during rendering would couple rendering to
              queue infrastructure.
            MD
          end
        end

        def lazy_on
          DocsUI::Section('Load on first use (reactive_lazy on:)') do
            md <<~MD
              Plain `reactive_lazy` defers server time but still makes its request
              on connect. `on:` defers the **request itself** — "load this panel the
              first time it opens", with no action, no loaded flag and no app
              JavaScript:

              ```ruby
              class ItemsPanel < ApplicationComponent
                include Phlex::Reactive::Component
                reactive_lazy on: "panel:opened"         # a DOM event on (or bubbling into) the shell
                # reactive_lazy on: :visible             # the shell first scrolls into view
                # reactive_lazy on: { visible: "200px" } # …with an IntersectionObserver rootMargin

                def id = "items-panel"
                def view_template = ul(id:, **reactive_attrs) { Current.user.items.each { li { it.name } } }
                def deferred_placeholder = ItemsSkeleton.new
              end
              ```

              The shell makes **no request on page load**. The first matching event
              (or the first intersection) materializes it **once**; later events are
              no-ops, because the real render never contains the shell or its
              trigger. `:visible` watches the shell itself with an
              `IntersectionObserver` and starts the request directly — no DOM event
              is involved, so a nested visible shell never materializes its
              ancestor. A positive rootMargin grows the observed region, so the
              shell loads a little before it scrolls into view; a negative one
              shrinks it, so the shell must scroll further in before it loads. In
              an engine without `IntersectionObserver` it materializes right after
              connect.

              Mechanics: an `on:` shell carries the component's **identity token** —
              the same one actions use, with no expiry — and a framework-owned
              `__materialize` trigger bound `once`, instead of a defer token. So it
              works on a page left open far longer than `defer_token_ttl`.
              `__materialize` rides the action endpoint (CSRF and auth from your base
              controller as usual), runs **no** action and opens no transaction, and
              renders through the same step as the defer endpoint: a registered
              authorization error from `from_identity`/render → **403**, `render?`
              false → an empty stream (the shell stays). It is instrumented as
              `defer.phlex_reactive` on the server; on the client it travels the
              action pipeline, so `have_reactive_requests` counts it under
              `kind: :action`. It answers **403** for any component that is not
              `reactive_lazy(on:)`, and `action :__materialize` is refused at
              declaration.

              **Failures.** A failed materialize (network drop, 4xx/5xx) marks the
              root `data-reactive-error` and fires `reactive:error`, as for any
              action. It is **not retried on its own**: an event shell's trigger is
              bound `once` and a visible shell stops observing when its request
              starts. The shell is re-armed by the next Turbo morph of the root
              (below), by `event.detail.retry()` from a `reactive:error` listener,
              or by the next page render.

              **Turbo morphs.** A page-refresh morph (or a `method="morph"` stream)
              rewrites the root in place and runs no Stimulus lifecycle, so the
              client handles it itself, on every morph of a reactive root:

              | The root before the morph | After the morph it is… | What happens |
              |---|---|---|
              | real content | real content | nothing — no request |
              | real content | the shell again | it re-materializes **at once**, one request per morph: it was loaded and the morph wiped it (for an event shell, the panel is already open and its event won't fire again) |
              | the shell (never triggered, or a failed load) | still the shell | it is **re-armed**: `:visible` observes again and loads on the next intersection; an event shell accepts its event again — this is a failed load's retry path |
              | the shell, load in flight | still the shell | nothing — the in-flight reply fills it; never a second request |

              This relies on the morph keeping the **same element**. Give the shell
              the real root's tag (`reactive_lazy on: "x", tag: :ul`): when the tags
              differ, Turbo swaps the node instead of morphing it, which is a fresh
              mount — a new shell that waits for its trigger like any other.
            MD
          end
        end

        def security
          DocsUI::Section('Security') do
            md <<~MD
              The defer token follows the same rules as every other token in
              phlex-reactive — **signed identity, never state**:

              - **Purpose-scoped.** Defer tokens are signed under a distinct purpose,
                so the two token families are non-interchangeable *by signature*: an
                action token posted to the defer endpoint is rejected (it must not
                become a render oracle), and a defer token can never invoke an action
                (it carries no action grant). Either confusion fails closed as a 400.
              - **Short-TTL.** A defer token expires after `defer_token_ttl` (default
                120 s) — it only needs to cover the reply-to-fetch gap. A leaked
                token is a render oracle for exactly one component identity until
                then.
              - **The signature is not authorization.** As with actions, auth comes
                from `Phlex::Reactive.base_controller_name` (session, CSRF), which
                applies to the defer endpoint like any reactive request. A component
                that guards visibility can raise a registered authorization error
                while being rebuilt or rendered (→ **403**) or return `false` from
                `render?` (→ **204**, keep content).
              - **`reactive_lazy(on:)` uses the identity token, not a defer token.**
                By opting in with `on:`, a component lets its identity token fetch
                its real render through the action endpoint — even a component that
                declares no actions. That is the same render a plain lazy shell's
                defer token fetches, minus the TTL, so treat the render as reachable
                by anyone holding the page and authorize inside it (raise a
                registered error, or `render?` false). `__materialize` is refused
                (403) for every component that didn't opt in with `on:`.
              - **`__materialize` is a read, and skips the action wrappers.** Like
                the defer endpoint, it does not run `Phlex::Reactive.around_actions`
                (rate limits, audit logs, tenant wrappers), the `verify_authorized`
                check, or the pgbus connection-id scope — and unlike a defer token,
                the token that reaches it never expires. Anything those wrappers
                enforce for this component (a tenant scope, a rate limit) must be
                enforced by your base controller or inside `from_identity`/the
                render itself.
            MD
          end
        end

        def config_reference
          DocsUI::Section('Configuration reference') do
            md <<~MD
              | Setting | Default | What it does |
              |---|---|---|
              | `Phlex::Reactive.defer_transport` | `:auto` | Lane selection: `:auto` / `:fetch` / `:stream` (see Delivery). Validated at assignment. |
              | `Phlex::Reactive.defer_token_ttl` | `120` | Defer-token lifetime in seconds. |
              | `Phlex::Reactive.defer_path` | `"/reactive/defer"` | Where the pull lane's endpoint is mounted. |
              | `Phlex::Reactive.defer_job_queue` | `"default"` | The ActiveJob queue the push lane's `DeferredRenderJob` runs on. |

              See it live on the [Deferred totals example](/docs/example-defer) — a
              deliberately slow rollup you can click, with the keep-content,
              skeleton, and synchronous-baseline variants side by side.
            MD
          end
        end
      end
    end
  end
end
