# frozen_string_literal: true

module Views
  module Docs
    module Pages
      class ExampleNotifications < DocsUI::Page
        title 'Notifications / live badges (pure broadcast, no client action)'
        eyebrow 'Examples'
        description 'Push live Rails notification badges with Streamable broadcasts and no client action — scope subscribers with visible_to and exclude the actor'

        def lead
          'Not every reactive component needs a client action — sometimes the server just pushes a re-render, ' \
            'using only Streamable broadcasts with no Component mixin.'
        end

        def content
          try_it
          intro
          badge
          who_receives
          suppress_echo
          light_the_bell
          pill
          error_surfaces
          when_to_use
          transactional_safety
        end

        private

        def try_it
          DocsUI::Section('Try it') do
            md <<~MD
              A **real** live bell. Click "Simulate a background event" — it stands
              in for a job finishing. The count bumps and the bell re-renders via a
              `broadcast_to(replace: ...)`, so **every tab** you have open on this
              page updates (open a second tab to see it). It also fires a
              `broadcast_to(js: ...)` pulse — a whitelisted DOM op, not HTML — so the
              bell on the *other* tabs bounces to grab attention, with no re-render at all.
            MD
            render Views::Examples::LiveExample.new(
              component: NotificationBellComponent.new(unread: 0),
              filename: 'app/components/notification_bell_component.rb'
            )
          end
        end

        def intro
          DocsUI::Section('When the server just pushes') do
            md <<~MD
              Not every reactive component needs a client action. Sometimes the
              server just needs to **push** a re-render — a notification badge that
              updates when a job finishes, a live metric, a “new items available”
              pill. This uses only `Phlex::Reactive::Streamable` (broadcasts), no
              `Component` mixin.
            MD
          end
        end

        def badge
          DocsUI::Section('A notification badge') do
            DocsUI::Code(badge_component_source, lexer: :ruby, filename: 'app/components/notifications_badge.rb')
            md <<~MD
              Subscribe on the page:
            MD
            DocsUI::Code(subscribe_source, lexer: :ruby)
            md <<~MD
              Push an update from anywhere — a model callback, a job, a service:
            MD
            DocsUI::Code(broadcast_source, lexer: :ruby)
            md <<~MD
              Now creating a notification re-renders the badge in every tab the user
              has open. No client action, no Stimulus, no Action Cable.
            MD
          end
        end

        def who_receives
          DocsUI::Section('Who receives the broadcast (visible_to:)') do
            md <<~MD
              A notifications stream is per-user by construction — you broadcast
              `current_user`'s unread badge *to that user*. But when several
              connections share one stream (a shared team channel, a per-account
              stream with multiple members), you need to say **which** subscribers a
              given broadcast may reach. Pass `visible_to:` — the transport-level
              authorization forwarded to pgbus — so a badge meant for one member
              never lights up in another's tab:
            MD
            DocsUI::Code(<<~RUBY, lexer: :ruby)
              # Only connections whose id is in this set receive the broadcast.
              NotificationsBadge.broadcast_to(
                account, :notifications, replace: user,
                visible_to: [user.reactive_connection_id]   # per-subscriber authorization
              )
            RUBY
            DocsUI::Callout(:warning) do
              md <<~MD
                `visible_to:` is the **security-relevant** knob for a shared
                notifications stream — it decides *who* receives the push.
                Broadcasting a user's unread count to the wrong subscribers leaks
                one person's activity into another's UI. Scope every shared-stream
                broadcast; a per-user stream (`broadcast_to(user, …)`) is already
                scoped by its key. `visible_to:` is honored on **pgbus**; on Action
                Cable it is inert (every subscriber of the stream receives it), so
                on Action Cable rely on a per-user stream key instead.
              MD
            end
          end
        end

        def suppress_echo
          DocsUI::Section("Suppress the actor's own echo (exclude:)") do
            md <<~MD
              When the person who *triggered* the change is also subscribed to the
              stream (they marked a notification read, and their own badge is live),
              the broadcast would echo back to the tab that already updated. Pass
              `exclude: reactive_connection_id` so the actor is skipped — they got
              their update from the action's own HTTP reply, not the broadcast:
            MD
            DocsUI::Code(<<~RUBY, lexer: :ruby)
              # Inside a reactive action on the badge (mark-all-read), or any
              # component method with access to reactive_connection_id:
              def mark_all_read
                @user.notifications.unread.update_all(read_at: Time.current)
                # Live-update every OTHER tab; this tab already re-rendered via the reply.
                NotificationsBadge.broadcast_to(
                  @user, :notifications, replace: @user,
                  exclude: reactive_connection_id
                )
                reply.replace
              end
            RUBY
            DocsUI::Callout(:note) do
              md <<~MD
                `reactive_connection_id` is the current action's connection id, from
                the `Phlex::Reactive::Component` mixin. `exclude:` and `visible_to:`
                are honored on **pgbus**; on the async Action Cable adapter this docs
                site runs, they are inert (the actor sees a harmless double-render).
              MD
            end
          end
        end

        def light_the_bell
          DocsUI::Section('Light up the bell without a re-render (broadcast_to js:)') do
            md <<~MD
              The classic notification nudge doesn't need a re-render at all — you
              just want a **has-unread** class on the bell in every viewer's tab.
              `broadcast_to(..., js: ops)` pushes declared client DOM ops (the same
              `js` builder as `on_client` / `reply.js`) over the stream, so the server
              lights the bell with **no HTML swap**:
            MD
            DocsUI::Code(<<~RUBY, lexer: :ruby)
              # In a model callback or job — light the bell in every viewer's tab,
              # minus the actor's own (who already knows).
              Notifications::Badge.broadcast_to(
                user, :alerts,
                js: js.add_class("#bell", "has-unread"),
                exclude: reactive_connection_id
              )
            RUBY
            DocsUI::Callout(:note) do
              md <<~MD
                `broadcast_to(..., js: ops)` **refuses the actor-only ops** (`focus` /
                `focus_first` / `submit` / `paste_into` / `check_group` raise `ArgumentError`) —
                broadcasting focus would steal it in every subscriber's tab, a broadcast
                submit would force-submit every form, and a broadcast clipboard read
                would be hostile; those stay actor-reply concerns (`reply.js`).
                Class and attribute toggles and `dispatch` broadcast fine. Like all
                client ops, these are **ephemeral**: the next full re-render of the
                component resets whatever they toggled, so use a signed `action` for
                state that must survive a re-render.
              MD
            end
          end
        end

        def pill
          DocsUI::Section('A “new items” pill driven by a background job') do
            DocsUI::Code(job_source, lexer: :ruby, filename: 'app/jobs/import_job.rb')
            DocsUI::Code(status_component_source, lexer: :ruby, filename: 'app/components/imports/status.rb')
          end
        end

        def error_surfaces
          DocsUI::Section('Surfacing a failed push to the user') do
            md <<~MD
              A notification the user *should* see is exactly where a silent failure
              hurts most. phlex-reactive has two built-in ways to surface one, and a
              way to make a flash clean itself up.

              **Self-dismissing flashes (`dismiss_after:`).** A notification flash
              that never clears piles up. Pass `dismiss_after:` (ms) and it removes
              itself after the timeout — driven by a document-level handler, so it
              self-cleans both reply-delivered **and** broadcast-delivered flashes:
            MD
            DocsUI::Code(<<~RUBY, lexer: :ruby)
              # In a reactive action — a flash the user sees for 4s, then it's gone.
              reply.replace.flash(:notice, "Marked all read", dismiss_after: 4000)

              # A broadcast flash self-cleans too (the container is a plain host div).
              NotificationsFlash.broadcast_to(
                user, :notifications, append: notification, target: "flash",
                exclude: reactive_connection_id
              )
            RUBY
            md <<~MD
              **`Phlex::Reactive.error_flash` — server-rendered flashes on endpoint
              failures.** For the failures the *endpoint* catches (bad token,
              default-deny, authorization, missing record — the 400/403/404 rescue
              paths behind a reactive action), set a lambda once and every one
              renders a turbo-stream flash the user sees, at the same status it
              already returns:
            MD
            DocsUI::Code(<<~'RUBY', lexer: :ruby, filename: 'config/initializers/phlex_reactive.rb')
              Phlex::Reactive.error_flash = ->(kind) { "Something went wrong (#{kind})." }
            RUBY
            md <<~MD
              The failing component's root also gets `data-reactive-error="<kind>"`,
              so you can outline it in **pure CSS** with zero JS — and the next
              successful action clears it:
            MD
            DocsUI::Code(<<~CSS, lexer: :css, filename: 'app/assets/stylesheets/reactive.css')
              [data-reactive-error] { outline: 2px solid var(--danger); }
            CSS
            DocsUI::Callout(:note) do
              md <<~MD
                For a failure your action *knows about* (a validation error, a
                business rule), return `reply.replace.flash(:error, "…")` directly —
                it renders at **200**, a normal reply, not an error. `error_flash` is
                for the failures the endpoint catches for you.
              MD
            end
          end
        end

        def when_to_use
          DocsUI::Section('When to use this vs a full reactive component') do
            md <<~MD
              - Server pushes a re-render (job, callback, another user) →
                `Streamable` + `broadcast_to`.
              - User clicks/types and the same component updates → add `Component` +
                `action`.
              - Both → add `Component`; broadcast from inside the action.

              Because both paths target the component by its `id`, you can start with
              a pure-broadcast badge and later add a `dismiss` action without
              changing the target or the subscription.
            MD
            DocsUI::Callout(:note, title: 'For a notifications LIST, not just a badge') do
              md <<~MD
                A notifications **list** — rows plus a count badge and an empty-state
                that toggle as it grows and shrinks — is the canonical
                `reactive_collection` case. Declare that whole contract once on the
                container and each action becomes a single `reply.append` /
                `reply.remove` (row + count + empty-state in one reply, the count
                re-counted server-side so it can't drift):

                ```ruby
                reactive_collection :notifications,
                  item: NotificationRow,          # the per-row Streamable component
                  container: "notifications",      # the DOM id rows live in
                  count: "notifications-count",    # optional companion id (the badge)
                  empty: NotificationsEmpty,       # optional empty-state component
                  size: -> { current_user.notifications.count }

                def dismiss(id:)
                  notification = current_user.notifications.find(id)
                  notification.destroy!
                  reply.remove(notification, from: :notifications)  # row + count + empty-state at 0
                end
                ```

                See [Reactive collections](/docs/example-collections) for the full
                add/remove-row contract.
              MD
            end
          end
        end

        def transactional_safety
          DocsUI::Section('Transactional safety') do
            md <<~MD
              If you broadcast from an `after_create_commit` / `after_update_commit`
              callback (or from inside a transaction with pgbus), the broadcast only
              fires once the change commits — a rolled-back notification never
              flashes a phantom badge.
            MD
          end
        end

        def badge_component_source
          <<~RUBY
            class NotificationsBadge < ApplicationComponent
              include Phlex::Reactive::Streamable

              def initialize(user:) = @user = user
              def id = dom_id(@user, :notifications_badge)
              def self.model_param_name = :user

              def view_template
                span(id:, class: "badge") do
                  count = @user.notifications.unread.count
                  plain(count.zero? ? "" : count.to_s)
                end
              end
            end
          RUBY
        end

        def subscribe_source
          <<~RUBY
            # in a layout or header component
            turbo_stream_from current_user, :notifications
          RUBY
        end

        def broadcast_source
          <<~RUBY
            class Notification < ApplicationRecord
              belongs_to :user
              after_create_commit do
                NotificationsBadge.broadcast_to(user, :notifications, replace: user)
              end
            end
          RUBY
        end

        def job_source
          <<~RUBY
            class ImportJob < ApplicationJob
              def perform(import)
                import.run!
                # Re-render a status component for everyone watching this import.
                Imports::Status.broadcast_to(import, replace: import)
              end
            end
          RUBY
        end

        def status_component_source
          <<~'RUBY'
            class Imports::Status < ApplicationComponent
              include Phlex::Reactive::Streamable

              def initialize(import:) = @import = import
              def id = dom_id(@import, :status)

              def view_template
                div(id:, class: "import-status #{@import.status}") do
                  plain @import.status.titleize
                  plain " — #{@import.processed_count}/#{@import.total_count}" if @import.running?
                end
              end
            end
          RUBY
        end
      end
    end
  end
end
