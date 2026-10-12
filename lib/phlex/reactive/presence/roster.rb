# frozen_string_literal: true

module Phlex
  module Reactive
    module Presence
      # The presence of one stream as one render reads it (issue #358): what
      # `presence` returns in a roster component's view_template and actions.
      # Built from the transport's rows once per render.
      #
      # A row is one SSE connection. Two presence roots in one tab are two
      # connections of one seat, so peers are grouped by seat: one entry per tab.
      class Roster
        include Enumerable

        def initialize(rows, keys:, connection_id: nil, writer: nil)
          # seat => its connection ids. Private: a connection id is the bearer
          # key for writing that row, so only `me` reads it.
          @connections = {}
          @peers = build_peers(rows, keys)
          @connection_id = connection_id
          @writer = writer
        end

        # Every tab, in join order.
        attr_reader :peers

        def each(&) = @peers.each(&)

        # The tabs grouped by person, in order of their first tab.
        def members
          @members ||= @peers.group_by(&:member_id).map do |id, seats|
            Member.new(id:, metadata: seats.last.metadata, seats:)
          end
        end

        # The tabs whose state matches, e.g. where(selected: item.id).
        def where(**state) = @peers.select { matches?(it, state) }

        def count = @peers.size

        alias size count

        def empty? = @peers.empty?

        # The actor's own tab during an action (found by its presence
        # connection), nil in a plain render or before the tab has connected.
        def me
          return if @connection_id.nil?

          @peers.find { @connections[it.seat].include?(@connection_id) }
        end

        # In an action: write the actor's tab state (merged into what it had),
        # morph the roster into the other viewers' tabs, return the actor's
        # peer. nil when the actor's tab has no presence connection yet.
        def set(**state) = @writer.call(state)

        private

        def matches?(peer, state) = state.all? { |key, value| peer.state[key] == value }

        # A row without a seat (a connection that sent no ?seat=: an app's own
        # turbo_stream_from of the stream, a source without `presence`, a stale
        # client) is no peer: no client can mark it "me", and keying it by its
        # connection id would render that id — the bearer key for its row.
        def build_peers(rows, keys)
          rows.select { it["seat"].present? }.group_by { it["seat"] }.map do |seat, seat_rows|
            first = seat_rows.first
            @connections[seat] = seat_rows.map { it["connection_id"] }
            Peer.new(
              seat:, member_id: first["id"].to_s, metadata: seat_rows.last["metadata"] || {},
              state: declared_state(seat_rows, keys), joined_at: first["joined_at"]
            )
          end
        end

        # The seat's state, declared keys only (never the reverse note), merged
        # across its connections in join order.
        def declared_state(seat_rows, keys)
          seat_rows.each_with_object({}) do |row, state|
            (row["state"] || {}).each do |key, value|
              key = key.to_sym
              state[key] = value if keys.include?(key)
            end
          end
        end
      end
    end
  end
end
