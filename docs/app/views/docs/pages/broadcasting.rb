# frozen_string_literal: true

module Views
  module Docs
    module Pages
      class Broadcasting < DocsUI::Page
        title 'Broadcasting & live updates'
        eyebrow 'Guide'
        description 'Broadcast reactive Phlex component updates over Turbo Streams or pgbus in Rails, pushing live cross-tab morphs to every subscriber by component id'

        def lead
          "Reactive actions update the acting user's screen; broadcasts update everyone " \
            "else's — both target the component by its id, so they compose."
        end

        def content
          pattern
          transports
          stream_keys
          methods_table
          model_mapping
          module_level_broadcast
          multi_key_fanout
          from_action
          url_options_contract
          actor_echo
          visible_to
          cross_tab_morph
          transactional
          removing_actor
          js_ops
          reply_js
          presence
        end

        private

        def pattern
          DocsUI::Section('The pattern') do
            render Components::Diagrams::BroadcastFanout.new
            md <<~MD
              Reactive **actions** update the acting user's screen. **Broadcasts**
              update everyone else's. Both target the component by its `id`, so they
              compose.

              ```ruby
              # Subscribe (in the view that should receive updates):
              turbo_stream_from @list, :todos

              # Broadcast (from a model callback, job, service, or a reactive action):
              Todos::Item.broadcast_to(@list, :todos, replace: @todo)
              ```

              The subscriber and broadcaster must agree on the **same stream key**.
              Pass the same `*streamables` to both `turbo_stream_from` and
              `broadcast_to`.
            MD
          end
        end

        def transports
          DocsUI::Section('Two transports: Action Cable or pgbus') do
            md <<~MD
              Every `broadcast_to` routes over `Turbo::StreamsChannel`, so it works
              on **either** transport with no code change:

              - **Action Cable** — the Rails default. Broadcasts go over WebSockets.
                Nothing extra to install.
              - **pgbus** — Postgres-backed SSE. Installing it makes the SAME
                `broadcast_to` calls route over Postgres instead, and unlocks the
                transactional guarantee, per-connection `exclude:` / `visible_to:`
                scoping, and presence tracking below.

              The plain broadcast API (`replace:` / `update:` / `append:` / `prepend:` /
              `remove:` / `js:` as the verb kwarg) is identical on both. What pgbus adds
              are the *guarantees* — the transactional deferral, actor-echo suppression,
              and presence — noted inline where they apply.
            MD
          end
        end

        def stream_keys
          DocsUI::Section('Stream keys: pass raw parts, not a built key') do
            md <<~MD
              `broadcast_to(*streamables, ...)` builds the stream key itself.
              **Pass raw parts** (a record and/or symbols), not an already-built key
              string:

              ```ruby
              # GOOD — raw parts
              Chat::Message.broadcast_to("chat", room, append: msg, target: "...")
              turbo_stream_from "chat", room

              # BAD — double-keying ("chat:lobby" then re-keyed) trips the separator guard
              key = ChatMessage.stream_key(room)             # => "chat:lobby"
              Chat::Message.broadcast_to(key, append: msg, target: "...")   # ArgumentError under pgbus
              ```

              If you have a helper that returns a built key for the subscriber, pass
              the **same built string** to `turbo_stream_from` only — but give
              `broadcast_to` the raw parts. The simplest rule: **use the same raw
              *streamables on both sides.**
            MD
          end
        end

        def methods_table
          DocsUI::Section('The broadcast method') do
            md <<~MD
              ONE method, `broadcast_to(*streamables, morph:, target:, exclude:,
              visible_to:, each:, **verb)` — the verb is a **kwarg** whose value is
              the payload, exactly one of:

              - `replace: model` — replace the element with id `component.id`. Pass
                `morph: true` for a cross-tab morph (see below).
              - `update: model` — replace its *inner* HTML. Pass `morph: true` for a
                cross-tab morph, so a peer editing the component keeps its
                focus/caret (see below).
              - `append: model` — append into container `target:`.
              - `prepend: model` — prepend into container `target:`.
              - `remove: model` — remove the element with id `component.id`.
              - `js: ops` — push **client DOM ops** (class/attr toggles, `dispatch`)
                to every subscriber. Refuses the actor-only ops —
                `focus`/`focus_first`/`submit`/`paste_into`/`persist_state`/`persist_clear`/`check_group` (see below).

              `replace:`/`remove:` self-target via the payload's `#id` (it must be a
              `Streamable`); `update:`/`append:`/`prepend:` are container verbs and
              take an explicit `target:` (or, for `update:`, default to
              self-targeting when `target:` is omitted). The payload itself is a
              record (built via `model_param_name`), an init-kwargs `Hash` (verbatim
              — no `**options` collision), or an already-built Phlex component.

              Every call accepts the transport options `exclude:` and `visible_to:`
              (honored on pgbus, ignored on Action Cable — see those sections).
            MD
          end
        end

        def model_mapping
          DocsUI::Section('How the verb payload maps to the init keyword') do
            md <<~MD
              A **record** payload (`replace: @todo`) is passed to the component's
              `initialize` under the keyword `model_param_name`. For a
              **record-backed** component (`reactive_record`), that keyword is the
              record name — the SAME keyword the action endpoint uses to rebuild the
              component on a click. So a single `initialize(<record>:)` satisfies
              both clicks and broadcasts:

              ```ruby
              class Todos::Item < ApplicationComponent
                include Phlex::Reactive::Component
                reactive_record :todo
                def initialize(todo:) = @todo = todo   # the keyword must match `reactive_record :todo`
              end

              Todos::Item.broadcast_to(@list, :todos, replace: @todo) # builds new(todo: @todo)
              ```

              For a **Streamable-only** component (broadcast-only, no
              `reactive_record`), `model_param_name` defaults to the demodulized,
              underscored class name. When the init keyword differs from that, override
              it:

              ```ruby
              class NotificationsBadge < ApplicationComponent
                include Phlex::Reactive::Streamable
                def initialize(user:) = @user = user
                def self.model_param_name = :user   # class name would be :notifications_badge
              end
              ```

              A **Hash** payload (`replace: { room:, author: }`) is passed as init
              kwargs **verbatim** — `new(**payload)` — with no `model_param_name`
              involved and no collision with a `**options` merge. An already-**built**
              Phlex component payload passes straight through unchanged.
            MD
          end
        end

        def module_level_broadcast
          DocsUI::Section('Broadcasting a plain component (Phlex::Reactive.broadcast_to)') do
            md <<~MD
              The class-level `SomeComponent.broadcast_to(...)` needs a `Streamable`
              class to call it on. When the thing you want to push is a **plain Phlex
              component** — a count badge, a summary card — that never carries
              `Streamable` itself, `Phlex::Reactive.broadcast_to` takes the same verb
              kwargs but the payload is an **already-built component instance**, so you
              never hand-roll the raw channel call + render:

              ```ruby
              Phlex::Reactive.broadcast_to(
                @list, :todos,
                update: TodoCount.new(list: @list), target: "todos-count"
              )
              Phlex::Reactive.broadcast_to(user, :alerts, replace: NotificationsBadge.new(user:))
              ```

              Self-targeting verbs (`replace:`/`remove:`) still need a `Streamable`
              payload (its `#id` is the target); container verbs (`update:`/`append:`/
              `prepend:`) accept **any** Phlex component. Both forms share the exact
              same render + instrumentation path, so an APM sees identical
              `broadcast.phlex_reactive` events either way.
            MD
          end
        end

        def multi_key_fanout
          DocsUI::Section('Render once, fan out to many keys (each:)') do
            md <<~MD
              `broadcast_to` concatenates its `*streamables` into **one** key. To push
              the *same* component to K **different** stream keys — a per-tenant loop,
              "the list page stream AND the dashboard stream" — a hand-written loop over
              `broadcast_to` pays K builds + K renders + K identity HMACs for
              **byte-identical HTML**. Pass `each:` instead of `*streamables` and it
              renders **once** and loops only the cheap channel call:

              ```ruby
              # K renders + K HMACs — the cliff
              accounts.each { |a| Counter.broadcast_to(a, :counters, replace: counter) }

              # 1 render + 1 HMAC + K channel calls — ~9.5× faster at K=10, ~88% fewer allocations
              Counter.broadcast_to(
                each: accounts.map { [it, :counters] }, replace: counter,
                exclude: reactive_connection_id
              )
              ```

              - **`each:`** is an enumerable of keys; each key is passed to the
                transport as its raw parts (a `[record, :symbol]` pair, or a bare
                string — both work). Same raw-parts rule as the single-key form.
              - **Every verb supports `each:`** — it's the same `broadcast_to` call,
                just swapping `*streamables` for `each: keys`.
              - **Transport opts + `morph:` forward per key** — `exclude:` /
                `visible_to:` are threaded to every stream exactly as the single-key
                form does, so the pgbus path suppresses the actor's echo on every stream
                and the Action Cable path is unchanged (the no-opts call passes no
                unknown keyword — the pgbus-optionality invariant holds).
              - **The irreducible exception is per-VIEWER content.** `visible_to:` that
                renders **different** HTML per viewer can't share a payload — that stays
                a render-per-call. `each:` is for the *same* payload to many keys.
            MD
          end
        end

        def from_action
          DocsUI::Section('Broadcasting from inside a reactive action') do
            md <<~MD
              The acting user gets the action's HTTP response (a replace of the
              component by default, or whatever `reply` the action returns). *Everyone
              else* gets the broadcast. Idiomorph dedupes a `replace` by DOM id, so the
              actor doesn't double-apply — but for `append` / `prepend` (and animations
              or optimistic UI) the echo *would* double-apply. Suppress the actor's own
              echo with `exclude: reactive_connection_id`:

              ```ruby
              def add(title:)
                authorize! @list, :update?
                todo = @list.todos.create!(title:)
                Todos::Item.broadcast_to(
                  @list, :todos,
                  append: todo,
                  target: dom_id(@list, :todos),
                  exclude: reactive_connection_id # don't echo to the actor — they got the HTTP response
                )
              end
              ```
            MD
          end
        end

        def url_options_contract
          DocsUI::Section('URLs in broadcast-rendered components: keep them host-relative') do
            md <<~MD
              A broadcast renders **off-request** — there is no acting request, and
              the subscribers can be on *different hosts* (multi-tenant apps,
              `lvh.me` subdomains). So a broadcast-rendered component that emits an
              **absolute** URL gets the process-default `url_options`, which is the
              wrong host for at least some subscribers. That makes host-relative
              URLs the contract:

              ```ruby
              # In a component that gets BROADCAST — host-relative, correct for every subscriber:
              img(src: rails_storage_proxy_path(@record.image))

              # Absolute (image_tag on an attachment resolves via polymorphic_url) —
              # renders the PROCESS-DEFAULT host in a broadcast. Avoid in broadcast paths:
              image_tag(@record.image)
              ```

              The actor's own **reply** is different: it renders *during* the request,
              so absolute URL helpers there carry the requesting protocol/host/port
              automatically — `image_tag(attachment)` is simply correct in a
              `reply.replace` / `reply.streams(...)` render. The same applies to a
              deferred segment fetched over the pull lane. But the *push* lane
              (`reply.defer` delivered via a job + SSE) and every `broadcast_to`
              render off-request: keep those host-relative.
            MD
          end
        end

        def actor_echo
          DocsUI::Section('Actor-echo suppression (exclude:)') do
            md <<~MD
              `reactive_connection_id` is the acting client's SSE connection id during
              the action (nil when the client isn't subscribed to a stream, or outside
              an action). The client sends it as `X-Pgbus-Connection`; the action
              endpoint exposes it. Passing it as `exclude:` tells the transport to skip
              delivery to that one connection — so the actor's truth is the HTTP
              response and they never get a duplicate.

              - **With pgbus**: fully honored — the dispatcher skips the excluded
                connection (pgbus ≥ the streams-reactive release).
              - **With Action Cable**: `exclude:` is accepted but ignored (Action Cable
                has no per-connection exclusion); rely on idiomorph dedup for `replace`
                / `update`.

              This is what makes optimistic UI safe: apply the change locally,
              broadcast with `exclude:`, and the actor never gets a conflicting echo of
              their own action.
            MD
          end
        end

        def visible_to
          DocsUI::Section('Scoping a broadcast (visible_to:)') do
            md <<~MD
              Where `exclude:` names ONE connection to skip, `visible_to:` names the
              only connections that should receive the broadcast — an allow-list rather
              than a deny-one. It is a first-class transport option on **every**
              `broadcast_to` call, alongside `exclude:`:

              ```ruby
              # Only these two connections see the update — everyone else on the stream
              # is skipped. Useful for a private DM row, a per-seat highlight, or a
              # moderator-only control.
              Chat::Message.broadcast_to(
                room, :messages,
                replace: msg,
                visible_to: [alice_connection_id, bob_connection_id]
              )
              ```

              Like `exclude:`, `visible_to:` is honored on **pgbus** (per-connection
              delivery) and **ignored on Action Cable** (which has no per-connection
              scoping — every subscriber of the stream receives the broadcast).
            MD
          end
        end

        def cross_tab_morph
          DocsUI::Section('Cross-tab morphing (broadcast_to morph:)') do
            md <<~MD
              A plain `broadcast_to(..., replace: model)` swaps the whole element. If a
              peer viewer is mid-interaction on that element — a text caret in an
              input, an open `<details>`, scroll position — a swap throws that state
              away. Pass `morph: true` to make the replace **morph in place** instead,
              so the peer tab keeps its focus and caret on the morphed row:

              ```ruby
              # A peer tab editing the same row keeps its caret; only the changed
              # attributes/text are patched in.
              Todos::Item.broadcast_to(@list, :todos, replace: @todo, morph: true)
              ```

              This emits `method="morph"` on the broadcast `<turbo-stream>`, so
              idiomorph patches the existing DOM rather than replacing it.

              `update:` takes `morph:` too — a plain `update` swaps the
              *inner* HTML (still tearing down a focused input mid-edit), so
              `morph: true` patches the inner HTML in place instead, keeping a peer's
              caret:

              ```ruby
              Totals.broadcast_to(@order, :totals, update: @order, morph: true)
              ```

              `append:` / `prepend:` / `remove:` don't replace an existing element, so
              they take no `morph:`.
            MD
          end
        end

        def transactional
          DocsUI::Section('Transactional broadcasts (with pgbus)') do
            md <<~MD
              The action endpoint runs your action inside a transaction. With pgbus,
              broadcasts defer to `after_commit`, so:

              - A broadcast inside a transaction that **rolls back never fires** — *and*
                the DB change is undone. No phantom UI update for a change that didn't
                happen.
              - This is the correctness property neither Action Cable nor Livewire give
                you cleanly.

              ```ruby
              ActiveRecord::Base.transaction do
                @order.update!(status: "shipped")
                Orders::Card.broadcast_to(@order.account, replace: @order)  # deferred
                ChargeService.capture!(@order)   # if this raises → no broadcast, no status change
              end
              ```
            MD
          end
        end

        def removing_actor
          DocsUI::Section("Removing the actor's own element") do
            md <<~MD
              `destroy`-style actions are the one case where "replace the component by
              its id" doesn't fit — the element should vanish, not be replaced. Return
              `reply.remove` from the action: the actor's element is removed via the
              built-in `Streamable#to_stream_remove` (no endpoint override, no helper to
              add), and other tabs get
              `broadcast_to(..., remove: model, exclude: reactive_connection_id)`.

              ```ruby
              def destroy
                authorize! @todo, :destroy?
                list = @todo.list
                @todo.destroy!
                # other tabs
                Todos::Item.broadcast_to(list, :todos, remove: @todo, exclude: reactive_connection_id)
                reply.remove # this tab
              end
              ```

              For an "undo" affordance, replace with a tombstone state instead of
              removing. See the **reply** API for the full set of reply controls.
            MD
          end
        end

        def js_ops
          DocsUI::Section('Pushing client DOM ops to everyone (broadcast_to js:)') do
            md <<~MD
              Sometimes a broadcast should nudge the UI rather than swap HTML — light up
              a bell, toggle a class, dispatch an app event. `broadcast_to(..., js:
              ops)` pushes the same `js` ops as `reply.js` to every subscriber, over the
              same transport (Action Cable or pgbus):

              ```ruby
              # Light up the bell in every viewer's tab, minus the actor's own connection.
              Notifications::Badge.broadcast_to(user, :alerts,
                js: js.add_class("#bell", "has-unread"), exclude: reactive_connection_id)
              ```
            MD
            DocsUI::Callout(:warning) do
              plain 'Actor-only ops are refused. '
              code { 'broadcast_to' }
              plain ' with '
              code { 'js:' }
              plain ' raises '
              code { 'ArgumentError' }
              plain ' for '
              code { 'focus' }
              plain '/'
              code { 'focus_first' }
              plain '/'
              code { 'submit' }
              plain '/'
              code { 'paste_into' }
              plain " — broadcasting focus would steal it in every subscriber's tab, a broadcast " \
                    "submit would force-submit every subscriber's form, and a broadcast clipboard " \
                    'read would be hostile. These are actor-reply concerns (use '
              code { 'reply.js' }
              plain ').'
            end
          end
        end

        def reply_js
          DocsUI::Section('Nudging the actor only (reply.js)') do
            md <<~MD
              `broadcast_to(..., js: ops)` is the *everyone* half. Its actor-side
              sibling is `reply.<verb>.js(ops)` — chained onto the reply the action
              returns, it runs client DOM ops on the **acting** user's tab only, and it
              does so AFTER the render streams. Because it rides after the render, a
              focus op sees the freshly rendered (or morphed) DOM:

              ```ruby
              def save(title:)
                @todo.update!(title:)
                # Morph in place, THEN focus the next field + tell a toast host we saved.
                # `focus` is legal here — it's the actor's OWN tab, not a broadcast.
                reply.morph.js(js.focus("[name=next_field]").dispatch("app:saved", detail: { id: @todo.id }))
              end
              ```

              `target:` scopes op resolution on the client; it defaults to the bound
              component's id for `replace` / `morph` / `update` (so `@root` and
              component-relative selectors just work), and to document-scope for a
              subject-free `reply.with`. This is why the focus example above is an
              actor-reply concern and `broadcast_to(..., js: ops)` refuses focus
              outright: `reply.js` targets one tab, a broadcast targets all of them.
            MD
          end
        end

        def presence
          DocsUI::Section("Presence (who's here / typing)") do
            md <<~MD
              pgbus ships presence tracking. Join on render, leave on disconnect,
              broadcast the change:

              ```ruby
              Pgbus.stream(@room).presence.join(
                member_id: current_user.id,
                metadata: { name: current_user.name }
              ) do |member|
                Chat::PresencePill.replace(member: member)  # rendered HTML to broadcast
              end

              Pgbus.stream(@room).presence.members   # current list
              Pgbus.stream(@room).presence.count     # fast count for a "N online" badge
              ```
            MD
            DocsUI::Callout(:tip) do
              plain 'See the pgbus transport guide for the full presence and SSE story.'
            end
          end
        end
      end
    end
  end
end
