# frozen_string_literal: true

module Phlex
  module Reactive
    module Presence
      # Every pgbus touchpoint of presence (issue #358), in one place. The
      # transport half lives in pgbus (zoolutions/pgbus#515): presence rows keyed
      # by SSE connection, each with the tab's seat and a state jsonb, a change
      # hook, and a heartbeat that expires silent rows. Nothing else in the gem
      # names a pgbus presence constant or configuration key.
      #
      # pgbus stays optional: the capability is a probe of the real method
      # signatures, never a version string, and without it nothing here runs —
      # reactive_presence raises a ConfigurationError at render instead.
      module Transport
        # Every presence stream's name ends in ":presence:<name>" — the parts
        # [record, :presence, name] joined by pgbus/Turbo. Registered with the
        # transport at boot so a subscription to one joins on connect and leaves
        # on disconnect, with no controller code.
        PATTERN = /:presence:[^:]+\z/

        # pgbus's default streams_heartbeat_interval (seconds), used when pgbus
        # is absent or does not expose the setting.
        DEFAULT_HEARTBEAT = 15

        # The change hook install! sets: the app's own hook (if any) first, then
        # presence's. Its class is how a second install! knows it is in place.
        ChainedHook = Data.define(:previous, :on_change) do
          def call(stream_name, change)
            previous&.call(stream_name, change)
            on_change.call(stream_name, change)
          end
        end

        class << self
          # The code is there: pgbus with reactive Streams AND presence keyed by
          # connection (a join that takes connection_id:, a set_state,
          # seats_supported?), a change hook and a ttl setting, and ActiveJob
          # (the roster re-renders off the hook's thread). Signatures only, no
          # query: boot and class load gate on this, and both run before a
          # database exists (`rails db:create`, `assets:precompile`). What it
          # gates is configuration, harmless on an unmigrated table.
          def wired?
            return false unless Phlex::Reactive.pgbus_streams?
            return false unless defined?(::Pgbus::Streams::Presence) && defined?(::ActiveJob::Base)

            presence = ::Pgbus::Streams::Presence
            join_keys = presence.instance_method(:join).parameters.map(&:last)
            return false unless join_keys.include?(:connection_id) && presence.method_defined?(:set_state)
            return false unless presence.respond_to?(:seats_supported?)

            config = ::Pgbus.configuration
            %i[streams_presence_on_change= streams_presence_ttl streams_presence_patterns].all? do
              config.respond_to?(it)
            end
          rescue ::NameError
            false
          end

          # Wired AND the seat table is migrated. seats_supported? is a query
          # (pgbus memoizes a success), so only a render and the render job ask.
          # A database error propagates: answering false would hide it.
          def capable?
            wired? && ::Pgbus::Streams::Presence.seats_supported?
          end

          # How often the transport's heartbeat touches a live tab (seconds):
          # configuration only, no query, so a declaration can read it at
          # class load.
          def heartbeat_interval
            config = ::Pgbus.configuration if Phlex::Reactive.pgbus? && ::Pgbus.respond_to?(:configuration)
            interval = config.streams_heartbeat_interval if config.respond_to?(:streams_heartbeat_interval)
            interval.is_a?(Numeric) ? interval : DEFAULT_HEARTBEAT
          end

          # The stream name the transport (and every Turbo broadcast) uses for
          # these parts.
          def stream_name(parts) = ::Pgbus::Streams::Stream.name_from(parts)

          # The signed SSE URL a <pgbus-stream-source> subscribes with.
          def source_src(stream_name) = Phlex::Reactive::Defer.stream_src(stream_name)

          # The rows of a stream: Hashes with "id" (the member), "connection_id",
          # "seat", "state", "metadata" and "joined_at".
          def members(stream_name) = ::Pgbus.stream(stream_name).presence.members

          # Writes the state of ONE connection's row on the stream (pgbus
          # shallow-merges it into what the row had).
          def set_state(stream_name, connection_id:, state:)
            ::Pgbus.stream(stream_name).presence.set_state(connection_id:, state:)
          end

          # At boot: auto-join presence streams, and hear their changes. An
          # app's own change hook keeps running (chained, first).
          def install!(on_change)
            config = ::Pgbus.configuration
            patterns = config.streams_presence_patterns
            patterns << PATTERN unless patterns.include?(PATTERN)
            previous = config.streams_presence_on_change
            return if previous.is_a?(ChainedHook)

            config.streams_presence_on_change = ChainedHook.new(previous:, on_change:)
          end

          # A component's ttl: — seconds a silent seat survives — keyed by its
          # presence name, which every stream of that component ends with.
          # pgbus takes an Integer (every stream) or a Hash of stream name /
          # pattern => seconds with a :default; an Integer becomes the Hash's
          # default so the app's own setting still covers every other stream.
          def register_ttl(name, seconds)
            config = ::Pgbus.configuration
            ttl = config.streams_presence_ttl
            config.streams_presence_ttl = ttl = { default: ttl } unless ttl.is_a?(Hash)
            ttl.store(/:presence:#{Regexp.escape(name.to_s)}\z/, seconds)
          end
        end
      end
    end
  end
end
