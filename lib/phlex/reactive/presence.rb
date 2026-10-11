# frozen_string_literal: true

module Phlex
  module Reactive
    # Presence (issue #358): who is viewing a stream, one SEAT per browser tab,
    # each with an ephemeral, declared state (the item it has selected), and a
    # roster component that re-renders itself in every viewer's tab on join,
    # leave, expiry and state change.
    #
    #   class Boards::Viewers < Phlex::HTML
    #     include Phlex::Reactive::Component
    #
    #     reactive_record :board
    #     reactive_presence :viewers, state: { selected: :integer }, ttl: 45
    #
    #     def view_template
    #       div(**reactive_root) do
    #         presence.members.each do |member|
    #           span(**reactive_presence_member(member)) { member.metadata["name"] }
    #         end
    #       end
    #     end
    #   end
    #
    # The transport does the membership (pgbus, zoolutions/pgbus#515): an SSE
    # connection to a presence stream joins on connect and leaves on
    # disconnect, a silent one expires after the stream's ttl, and each change
    # calls the hook this module installs. The hook enqueues
    # PresenceRenderJob, which re-renders the roster for everyone.
    #
    # Every pgbus call is in Presence::Transport. Without a capable transport
    # (no pgbus, an older one, Action Cable) a presence root raises
    # Phlex::Reactive::ConfigurationError at render: there is no degraded mode.
    module Presence
      # The reverse note a presence write leaves in the seat's state: the class
      # that wrote it and the record it renders. A stream name cannot be turned
      # back into a record (pgbus digests long names), so the render job reads
      # this from any seat still on the stream. Never shown to the app: Peer#state
      # holds only the declared keys.
      NOTE_KEY = "_rp"

      # A silent seat survives this many seconds (the transport's heartbeat,
      # 15 s by default, keeps a live one fresh: two missed beats).
      DEFAULT_TTL = 45

      # Roster broadcasts coalesce: a page reload is a leave and a join within
      # milliseconds, and a burst of selections is one morph per window.
      COALESCE_MS = 150

      # The client sends its presence source's connection id in this header, so
      # a write lands on the row of THIS tab's presence connection — not on the
      # first <pgbus-stream-source> on the page (X-Pgbus-Connection).
      HEADER = "X-Reactive-Presence"

      # What reactive_presence declared: the presence name, the state schema,
      # the ttl, and the raw stream key parts of a record-less component.
      Declaration = Data.define(:name, :state, :ttl, :key)

      # One tab on the stream. `seat` is the tab's id (opaque; rendered by
      # reactive_presence_peer so the client can find "me"), `state` the
      # declared keys only. No connection id: it is the bearer key for writing
      # the tab's row, so it stays inside the Roster.
      Peer = Data.define(:seat, :member_id, :metadata, :state, :joined_at)

      # One person: their seats, the newest one's metadata and state.
      Member = Data.define(:id, :metadata, :seats) do
        def state = seats.last&.state || {}
      end

      class << self
        # Wired and migrated (a query: render time only). See Transport.
        def capable? = Transport.capable?

        # The actor's presence connection during an action (the HEADER), or nil.
        def connection_id
          Thread.current[:phlex_reactive_presence_connection]
        end

        def with_connection_id(connection_id)
          previous = Thread.current[:phlex_reactive_presence_connection]
          Thread.current[:phlex_reactive_presence_connection] = connection_id.presence
          yield
        ensure
          Thread.current[:phlex_reactive_presence_connection] = previous
        end

        # Raise unless the transport can carry presence — at first render of a
        # presence root, naming what is missing.
        def require_capable!(klass)
          return if capable?

          raise Phlex::Reactive::ConfigurationError,
            "#{klass.name} declares reactive_presence, which needs pgbus with reactive Streams and " \
            "presence keyed by SSE connection (zoolutions/pgbus#515: Presence#join(connection_id:), " \
            "#set_state, config.streams_presence_on_change) with its seat table migrated " \
            "(`rails g pgbus:add_presence_seats`, or `rails pgbus:update`), and ActiveJob. Action Cable " \
            "has no connection identity, so there is no fallback."
        end

        # Boot (the engine's after_initialize): register the presence stream
        # pattern and the change hook. Gated on the signatures alone, never a
        # query — boot runs before a database exists. Nothing is touched
        # without them: an app on Action Cable boots exactly as before.
        def install!
          Transport.install!(method(:changed)) if Transport.wired?
        end

        # The transport's change hook (it runs on the SSE dispatcher thread):
        # enqueue a roster render for a presence stream, nothing else.
        def changed(stream_name, _change)
          return unless Transport::PATTERN.match?(stream_name.to_s)

          Phlex::Reactive::PresenceRenderJob.perform_later(stream_name.to_s)
        end

        # The job's body: rebuild every roster component a seat on the stream
        # names, render it as the table is NOW, and morph it into every viewer's
        # tab (the joiner included: its first paint ran before its connection
        # existed). Nobody left, or a gone record, renders nothing.
        def render_roster(stream_name)
          return unless capable?

          notes = Transport.members(stream_name).filter_map { it["state"]&.[](NOTE_KEY) }.uniq
          notes.each do
            component = build(it)
            broadcast(component, exclude: nil) if component
          end
        end

        # Morph `component`'s roster into its stream's viewers.
        def broadcast(component, exclude:)
          Phlex::Reactive::Streamable.broadcast_component(
            component.class, :replace, component, component, [component.reactive_presence_stream_parts],
            morph: true, target: nil, exclude:, visible_to: nil, coalesce: COALESCE_MS
          )
        end

        # A roster component rebuilt from a note: the named class, only when it
        # declares presence, with its record re-found (nil when it is gone).
        def build(note)
          klass = note["c"].to_s.safe_constantize
          return unless klass.respond_to?(:reactive_presence_declaration) && klass.reactive_presence_declaration

          payload = note["gid"] ? { "gid" => note["gid"] } : {}
          klass.from_identity(payload)
        rescue ::ActiveRecord::RecordNotFound
          nil
        end
      end
    end
  end
end
