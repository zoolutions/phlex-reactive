# frozen_string_literal: true

module Phlex
  module Reactive
    module Presence
      # What reactive_presence adds to a component (issue #358). Included only
      # by a class that declares presence, so every other component keeps
      # ActiveSupport's Object#presence.
      module ComponentMethods
        # The roster, read once per render (and again after #presence.set). The
        # memo is namespaced: a component's own @presence must not be clobbered.
        def presence
          @reactive_presence_roster ||= Roster.new( # rubocop:disable Naming/MemoizedInstanceVariableName
            Transport.members(reactive_presence_stream_name),
            keys: self.class.reactive_presence_declaration.state.keys,
            connection_id: Presence.connection_id,
            writer: -> { reactive_presence_write(it) }
          )
        end

        # The generated action js.presence sends. Runs authorize_presence_state!
        # first when the component defines it (raise to refuse), writes the
        # actor's tab state, and morphs the actor's own view.
        #
        # The client also sends it EMPTY on every connect (the announce). That
        # writes no value — only the reverse note (this class and the record of
        # the token the actor already holds) on the actor's own row — so there
        # is nothing to authorize, and the hook is skipped: its keywords may be
        # required, and calling it with none would raise.
        def presence_set(**state)
          authorize_presence_state!(**state) if state.any? && respond_to?(:authorize_presence_state!, true)
          presence.set(**state)
          reply.morph
        end

        # data-reactive-presence-peer / -member on a tab's element: the client
        # marks the one that is this tab ("me") and this person's other tabs.
        def reactive_presence_peer(peer)
          { data: { reactive_presence_peer: peer.seat.to_s, reactive_presence_member: peer.member_id.to_s } }
        end

        # data-reactive-presence-member / -seats on a person's element.
        def reactive_presence_member(member)
          { data: { reactive_presence_member: member.id.to_s, reactive_presence_seats: member.seats.size.to_s } }
        end

        # [record, :presence, name] — or [*key, :presence, name] record-less.
        def reactive_presence_stream_parts
          declaration = self.class.reactive_presence_declaration
          [*reactive_presence_subject, :presence, declaration.name]
        end

        def reactive_presence_stream_name
          @reactive_presence_stream_name ||= reactive_presence_key(reactive_presence_stream_parts)
        end

        # The root's subscription marker (reactive_attrs): the signed SSE src of
        # the presence stream. The client mints the <pgbus-stream-source> from it.
        # And the seats this render saw: a template need not render an element
        # per tab, so the client diffs these for reactive:presence and checks
        # them to know its own tab is on the roster. Seats only (pgbus limits
        # them to [A-Za-z0-9_-]), never a member or connection id.
        def reactive_presence_data
          Presence.require_capable!(self.class)
          { reactive_presence: Transport.source_src(reactive_presence_stream_name),
            reactive_presence_roster: presence.peers.filter_map(&:seat).join(" ") }
        end

        private

        # The stream key for the parts. Only pgbus's budget error becomes a
        # ConfigurationError (the backstop for a name the declaration could not
        # check); a missing key keeps its own error.
        def reactive_presence_key(parts)
          Transport.stream_name(parts)
        rescue ::ArgumentError => e # pgbus raises the core one; Phlex defines its own
          raise ConfigurationError, Transport.over_budget_message(self.class, parts.last, e.message)
        end

        def reactive_presence_subject
          declaration = self.class.reactive_presence_declaration
          return declaration.key if declaration.key

          record_key = self.class.reactive_record_key
          unless record_key
            raise ArgumentError,
              "#{self.class.name}: reactive_presence needs reactive_record (the stream is the record's) " \
              "or key: (the raw stream key parts of a record-less roster)"
          end

          [instance_variable_get(:"@#{record_key}")]
        end

        def reactive_presence_write(state)
          declared = self.class.reactive_presence_declaration.state.keys
          unknown = state.keys.map(&:to_sym) - declared
          unless unknown.empty?
            raise ArgumentError,
              "#{self.class.name}: presence.set got undeclared state #{unknown.join(", ")} " \
              "(declared: #{declared.join(", ")})"
          end

          connection_id = Presence.connection_id
          return if connection_id.nil?

          merged = (presence.me&.state || {}).merge(state.transform_keys(&:to_sym)).transform_keys(&:to_s)
          written = Transport.set_state(reactive_presence_stream_name, connection_id:,
            state: merged.merge(NOTE_KEY => reactive_presence_note))
          @reactive_presence_roster = nil
          # No row for this connection (it expired, or pgbus never joined it:
          # no identity): nothing changed for the peers.
          return if written.nil?

          # A seatless actor (no ?seat=) is on no roster: nothing any viewer
          # sees changed, so there is nothing to broadcast.
          me = presence.me
          return if me.nil?

          Presence.broadcast(self.class.from_identity(reactive_identity_payload), exclude: connection_id)
          me
        end

        # Which component wrote the row: its identity payload (class, record gid,
        # declared reactive_state), which is how the render job rebuilds it from
        # the stream (see Presence::NOTE_KEY) — the same shape a token carries.
        def reactive_presence_note = reactive_identity_payload
      end
    end
  end
end
