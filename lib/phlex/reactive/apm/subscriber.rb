# frozen_string_literal: true

module Phlex
  module Reactive
    module APM
      # The ASN-driven half of the APM integration (issue #207). Subscribes to
      # action.phlex_reactive / defer.phlex_reactive and hands each event's
      # name-only payload + duration to the resolved adapter's record_action —
      # so the APM names the transaction `Component#action` and tags the outcome.
      #
      # A plain ActiveSupport::Notifications subscriber (NOT a LogSubscriber): a
      # LogSubscriber dispatches by the FULL event method, but we want the SAME
      # record_action for both action and defer events and to hold a reference to
      # the adapter instance. install/uninstall manage exactly one subscription so
      # a re-attach with the same adapter never double-reports.
      class Subscriber
        # The events whose duration+outcome we forward to the APM as a named
        # transaction. render/broadcast are left to the app (a Datadog child-span
        # adapter can subscribe to them itself) — the action IS the transaction.
        EVENTS = /\A(?:action|defer)\.phlex_reactive\z/

        # The one subscription and its adapter, class ivars on purpose and
        # safe: install/uninstall run at boot, from the engine's
        # after_initialize on the main Ractor (APM.attach!), and between
        # examples in a test suite; the request path never touches them.
        # rubocop:disable-next ThreadSafety/ClassInstanceVariable
        class << self
          # Install a single bus subscription for `adapter`. Idempotent for the
          # SAME adapter: a repeat call is a no-op. A DIFFERENT adapter replaces
          # the previous subscription (an app that swaps apm at boot wins last).
          def install(adapter)
            return if @adapter.equal?(adapter) && @subscription

            uninstall
            @adapter = adapter
            subscriber = new(adapter)
            @subscription = ::ActiveSupport::Notifications.subscribe(EVENTS) do |*args|
              subscriber.call(::ActiveSupport::Notifications::Event.new(*args))
            end
          end

          def uninstall
            ::ActiveSupport::Notifications.unsubscribe(@subscription) if @subscription
            @subscription = nil
            @adapter = nil
          end

          def installed? = !@subscription.nil?
        end

        def initialize(adapter)
          @adapter = adapter
        end

        # Route an already-built Event to record_action. Named after the event's
        # leading segment (action/defer) so the synthesized-event unit spec can
        # call subscriber.action(event) exactly like the LogSubscriber spec.
        def call(event)
          @adapter.record_action(event.payload, event.duration)
        end
        alias action call
        alias defer call
      end
    end
  end
end
