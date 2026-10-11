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
          @reactive_presence_stream_name ||= Transport.stream_name(reactive_presence_stream_parts)
        end

        # The root's subscription marker (reactive_attrs): the signed SSE src of
        # the presence stream. The client mints the <pgbus-stream-source> from it.
        def reactive_presence_data
          Presence.require_capable!(self.class)
          { reactive_presence: Transport.source_src(reactive_presence_stream_name) }
        end

        private

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
          Transport.set_state(reactive_presence_stream_name, connection_id:,
            state: merged.merge(NOTE_KEY => reactive_presence_note))
          @reactive_presence_roster = nil
          Presence.broadcast(self.class.from_identity(reactive_identity_payload), exclude: connection_id)
          presence.me
        end

        # Which component wrote the row, and its record: how the render job
        # rebuilds it from the stream (see Presence::NOTE_KEY).
        def reactive_presence_note
          record = reactive_presence_subject.first unless self.class.reactive_presence_declaration.key
          note = { "c" => self.class.name }
          note["gid"] = record.to_gid.to_s if record
          note
        end
      end
    end
  end
end
