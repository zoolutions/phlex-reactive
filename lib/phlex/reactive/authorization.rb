# frozen_string_literal: true

module Phlex
  module Reactive
    # The runtime machinery behind verify_authorized (issue #168): a time-window
    # tracking cell, an interceptor that marks it when a configured authorization
    # method returns, and the enforcement decision the endpoint calls after an
    # action runs.
    #
    # The design mirrors Phlex::Reactive.with_connection_id: a fiber-local cell
    # (Thread.current, which is fiber-local in Ruby, so Falcon's fiber-per-request
    # model is safe) saved and restored around the action. Because tracking is a
    # WINDOW — anything marking during the action counts — authorization performed
    # in a HELPER the action calls is detected too, not just a top-level call.
    module Authorization
      # The fiber-local key holding the tracking cell during an action. A truthy
      # value means "some authorization method has been called (and returned)
      # during this window".
      CELL = :phlex_reactive_authorized

      # Streamable defines a CLASS method `prepend(target:, model:)` (the Turbo
      # Stream verb), which shadows Ruby's Module#prepend on a component class.
      # Bind the real Module#prepend so instrument! can prepend the interceptor
      # module without dispatching to the stream helper (and its keyword arity).
      MODULE_PREPEND = ::Module.instance_method(:prepend)
      private_constant :MODULE_PREPEND

      # The per-Ractor lock (Phlex::Reactive::Store) the lazy instrument! path
      # holds: one per Ractor, never shared across Ractors.
      INSTRUMENT_LOCK_KEY = :phlex_reactive_authorization_instrument_lock

      class << self
        # Open a fresh tracking window, run the block, and restore the previous
        # cell — exactly the with_connection_id save/restore shape, so nesting is
        # correct and a raise still restores. The inner window starts UNMARKED
        # regardless of an outer mark (a fresh action authorizes for itself).
        def with_tracking
          previous = Thread.current[CELL]
          Thread.current[CELL] = false
          yield
        ensure
          Thread.current[CELL] = previous
        end

        # Mark the current window authorized. Called by the interceptor (on a
        # non-raising authorization-method return) and by Component#mark_authorized!
        # for a bespoke check. A no-op semantically outside a window (the cell is
        # simply overwritten and restored by the nearest with_tracking).
        def mark!
          Thread.current[CELL] = true
        end

        # Has anything marked the current window?
        def marked?
          Thread.current[CELL] == true
        end

        # The enforcement decision, called by the endpoint AFTER the action runs,
        # INSIDE the transaction (so a raise rolls the mutation back). A no-op
        # unless verify_authorized is on, the action isn't skipped, and nothing
        # marked the window. Otherwise raises AuthorizationNotVerified naming the
        # component#action and the three remedies.
        def verify!(component_class, action_def)
          return unless Phlex::Reactive.verify_authorized
          return if skipped?(component_class, action_def.name)
          return if marked?

          raise Phlex::Reactive::AuthorizationNotVerified, violation_message(component_class, action_def)
        end

        # Wrap each configured authorization method the class defines (public OR
        # private, own OR inherited) with a prepended module that calls super and
        # then mark! on a NON-RAISING return — so a denial (which raises) never
        # marks and still propagates to the endpoint's authorization_errors → 403.
        #
        # Idempotent per class OBJECT (memoized on an ivar the class carries), so
        # a Zeitwerk reload's fresh class re-instruments naturally and a repeated
        # call in one process is a no-op. Re-reads authorization_methods each first
        # call, so an initializer that widened the list is honored.
        #
        # When the app eager-loads, the engine instruments every component class
        # at boot (instrument_all!, zoolutions/phlex-reactive#364), so the
        # endpoint's call is a bare "already instrumented" read and a request
        # never mutates a class. The lazy path (development, or a class defined
        # after boot) holds a lock across the check and the prepend, so two
        # threads first-calling it for one class prepend ONE interceptor.
        def instrument!(component_class)
          return if instrumented?(component_class)

          Phlex::Reactive::Store.fetch(INSTRUMENT_LOCK_KEY) { Mutex.new }.synchronize do
            next if instrumented?(component_class)

            names = Phlex::Reactive.authorization_methods.select do
              component_class.method_defined?(it) || component_class.private_method_defined?(it)
            end
            MODULE_PREPEND.bind_call(component_class, interceptor_for(names)) if names.any?
            component_class.instance_variable_set(:@reactive_authorization_instrumented, true)
          end
        end

        # Instrument every reactive component class among `classes` (the
        # engine passes Streamable.registered_classes at boot, after eager
        # loading). Plain Streamable classes have no actions to guard.
        def instrument_all!(classes)
          classes.each { instrument!(it) if it.include?(Phlex::Reactive::Component) }
        end

        def instrumented?(component_class)
          component_class.instance_variable_get(:@reactive_authorization_instrumented) ? true : false
        end

        private

        def skipped?(component_class, action_name)
          component_class.respond_to?(:skip_verify_authorized?) &&
            component_class.skip_verify_authorized?(action_name)
        end

        # Build the prepend module: one wrapper per authorization method name,
        # each `super(...)` then mark! (only reached when super didn't raise).
        def interceptor_for(names)
          Module.new do
            names.each do
              define_method(it) do |*args, **kwargs, &block|
                result = super(*args, **kwargs, &block)
                Phlex::Reactive::Authorization.mark!
                result
              end
            end
          end
        end

        def violation_message(component_class, action_def)
          where = [component_class&.name, action_def&.name].compact.join("#")
          methods = Phlex::Reactive.authorization_methods.map { ":#{it}" }.join(", ")
          "#{where} completed without any authorization call — verify_authorized is on. " \
            "Either call one of your authorization methods (#{methods}), call mark_authorized! " \
            "for a bespoke check, or declare `skip_verify_authorized` (whole component) / " \
            "`skip_verify_authorized :#{action_def&.name}` (this action) if it is intentionally public."
        end
      end
    end
  end
end
