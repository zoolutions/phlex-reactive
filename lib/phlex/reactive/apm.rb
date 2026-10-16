# frozen_string_literal: true

module Phlex
  module Reactive
    # Turnkey APM integration (issue #207). The gem already emits `*.phlex_reactive`
    # ActiveSupport::Notifications events (issue #107); this namespace turns them
    # into per-component visibility in AppSignal / Sentry / Datadog with ONE config
    # line — `Phlex::Reactive.apm = :appsignal` — instead of every app hand-writing
    # the subscribe block and each vendor's transaction-naming / error-tagging API.
    #
    # The vendor adapters are RUNTIME capability-detected (`defined?(::Appsignal)`
    # etc.), never a gemspec dependency — the same optionality invariant as pgbus.
    # A set-but-absent SDK logs one warning and no-ops.
    module APM
      # Symbol => built-in adapter class. Resolved lazily (at attach time), so the
      # adapter class is only referenced when an app actually opts into it.
      BUILT_INS = {
        appsignal: "Phlex::Reactive::APM::Appsignal",
        sentry: "Phlex::Reactive::APM::Sentry",
        datadog: "Phlex::Reactive::APM::Datadog"
      }.freeze

      class << self
        # Resolve `Phlex::Reactive.apm` to a live adapter instance, or nil.
        #   * nil            -> nil (off; no warning)
        #   * an object      -> returned verbatim (a custom adapter)
        #   * a known Symbol -> the built-in adapter instance IF its SDK is loaded,
        #                       else nil + one warning
        #   * an unknown Symbol -> nil + one warning
        def detect(apm)
          return nil if apm.nil?
          return apm unless apm.is_a?(Symbol)

          klass_name = BUILT_INS[apm]
          unless klass_name
            known = BUILT_INS.keys.map(&:inspect).join(", ")
            return warn_and_nil("apm = #{apm.inspect} — unknown APM flavour (known: #{known})")
          end

          klass = klass_name.constantize
          # Memoize the instance PER SYMBOL so repeated detect/attach! calls return
          # the SAME object — Subscriber.install keys idempotency on adapter
          # identity (equal?), so a fresh klass.new each time would double-subscribe.
          return built_in_instances.fetch(apm) { klass.new } if klass.available?

          warn_and_nil("apm = #{apm.inspect} set but #{apm} is not loaded — no-op. " \
                       "Require the SDK (or remove the setting).")
        end

        # Attach the APM Subscriber to the notification bus if an adapter resolves.
        # Called once from the engine's after_initialize when Phlex::Reactive.apm
        # is set. Idempotent within a boot: a second call with the SAME adapter is
        # a no-op. Returns the attached adapter (or nil when nothing resolved).
        def attach!(apm = Phlex::Reactive.apm)
          adapter = detect(apm)
          return nil unless adapter

          Subscriber.install(adapter)
          # Hold the adapter so the endpoint's error seam (report_error) can reach
          # record_error without re-running detection per request.
          Phlex::Reactive.resolved_apm_adapter = adapter
          adapter
        end

        # Drop the installed subscriber + adapter AND the memoized built-in
        # instances. Tests only (so a stubbed SDK doesn't leak a stale adapter into
        # the next example).
        def reset!
          Subscriber.uninstall
          Phlex::Reactive.resolved_apm_adapter = nil
          built_in_instances.clear
        end

        private

        # Symbol => memoized built-in adapter instance. One instance per flavour for
        # the life of the process (cleared only by reset! in tests), so detect is
        # identity-stable and attach! stays idempotent. Per-Ractor state
        # (Phlex::Reactive::Store), not a module ivar (zoolutions/phlex-reactive#364).
        def built_in_instances = Phlex::Reactive::Store.table(:phlex_reactive_apm_adapters)

        def warn_and_nil(message)
          logger = Phlex::Reactive.send(:default_logger)
          logger&.warn("[phlex-reactive] #{message}")
          nil
        end
      end
    end
  end
end
