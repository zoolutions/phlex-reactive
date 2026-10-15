# frozen_string_literal: true

module Phlex
  module Reactive
    # Per-Ractor lazy state (zoolutions/phlex-reactive#364): the home for a
    # process cache that must not live in a constant or a class instance
    # variable, where a non-main Ractor could not read it (a Mutex or a
    # mutable Hash is never Ractor-shareable) and never write it.
    #
    #   Store.fetch(:phlex_reactive_thing) { build }  # one value per Ractor
    #   Store.table(:phlex_reactive_memo).fetch(key) { compute }
    #
    # On an engine with Ractor.store_if_absent (MRI 3.4+, so every Ruby
    # phlex-reactive supports there) this is that: atomic, one value per
    # Ractor. An engine without Ractors (JRuby, TruffleRuby) has only one, so
    # one Mutex-guarded FALLBACK table stands in. Keys are Symbols prefixed
    # with the gem's name. The pattern is conformance-kit's
    # ConformanceKit::Store, copied here because the kit is a development
    # dependency only.
    module Store
      # A Hash guarded by its own Mutex: the per-Ractor memo the threads of one
      # Ractor share. Built inside the Ractor that uses it, so the lock is
      # never shared across Ractors.
      class Table
        def initialize
          @mutex = Mutex.new
          @values = {}
        end

        # The value under key, computed once with the block when absent.
        def fetch(key)
          @mutex.synchronize { @values.fetch(key) { @values[key] = yield } }
        end

        # True the first time key is claimed (until #clear), false after: a
        # once-per-Ractor guard, e.g. for a warning.
        def claim?(key)
          @mutex.synchronize { @values.key?(key) ? false : (@values[key] = true) }
        end

        def clear
          @mutex.synchronize { @values.clear }
        end
      end

      NATIVE = defined?(::Ractor) ? ::Ractor.respond_to?(:store_if_absent) : false
      # Only an engine without Ractor.store_if_absent builds it: on MRI the
      # module holds no lock and no mutable state at all.
      FALLBACK = (Table.new unless NATIVE)

      # The table of the once-per-process config warnings (Defer, Pending):
      # once per Ractor, which in practice is the main one.
      WARNINGS_KEY = :phlex_reactive_warnings

      class << self
        def fetch(key, &init)
          raise ::ArgumentError, "Phlex::Reactive::Store.fetch(#{key.inspect}) needs an initializer block" unless init
          return ::Ractor.store_if_absent(key, &init) if native?

          FALLBACK.fetch(key, &init)
        end

        # The current Ractor's Table under key.
        def table(key) = fetch(key) { Table.new }

        # True the first time the named warning is due in this Ractor.
        def first_warning?(name) = table(WARNINGS_KEY).claim?(name)

        def native? = NATIVE
      end
    end
  end
end
