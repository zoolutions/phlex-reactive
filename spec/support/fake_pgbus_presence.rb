# frozen_string_literal: true

# A stand-in for pgbus with per-connection presence (zoolutions/pgbus#515,
# issue #358). The default suite runs WITHOUT pgbus, so the presence specs stub
# its constants with these doubles. Each method mirrors one line of the
# "Assumed pgbus #515 API" stitch list; swapping in the real pgbus means
# deleting this file and running the specs against it.
module FakePgbusPresence
  # One process-wide table: { stream_name => { connection_id => row } }.
  Store = Struct.new(:rows, :order) do
    def initialize = super({}, 0)

    def next_order = (self.order += 1)
  end

  # The #515 shape: rows keyed by connection, a seat and a state per row.
  class Presence
    def initialize(store, stream_name)
      @store = store
      @stream_name = stream_name
    end

    def self.seats_supported? = true

    def join(member_id:, metadata: {}, connection_id: nil, seat: nil)
      table[connection_id] = {
        "id" => member_id.to_s, "connection_id" => connection_id, "seat" => seat,
        "state" => {}, "metadata" => metadata.transform_keys(&:to_s),
        "joined_at" => format("2026-10-11T00:00:%02d", @store.next_order)
      }
    end

    def leave(member_id: nil, connection_id: nil)
      return table.delete(connection_id) if connection_id

      table.delete_if { |_, row| row["id"] == member_id.to_s }
    end

    # Shallow-merges into the row's state (#515); the row, or nil. Like
    # pgbus, a state that is not a Hash raises.
    def set_state(connection_id:, state:)
      raise ArgumentError, "state must be a Hash, got #{state.class}" unless state.is_a?(Hash)

      row = table[connection_id]
      row && (row["state"] = row["state"].merge(JSON.parse(JSON.generate(state)))) && row
    end

    def members = table.values.sort_by { it["joined_at"] }.map(&:dup)

    private

    def table = (@store.rows[@stream_name] ||= {})
  end

  # The pre-#515 shape: one row per member, no connection, no state.
  class OldPresence
    def initialize(*); end

    def join(member_id:, metadata: {}) = [member_id, metadata]

    def members = []
  end

  class Stream
    attr_reader :name, :presence

    def initialize(name, presence)
      @name = name
      @presence = presence
    end

    def self.name_from(streamables)
      return streamables.map { name_from(it) }.join(":") if streamables.is_a?(Array)
      return streamables.to_gid_param if streamables.respond_to?(:to_gid_param)

      streamables.to_s
    end

    def broadcast(payload, visible_to: nil, durable: nil, exclude: nil, event: nil, coalesce: nil, target: nil)
      [payload, visible_to, durable, exclude, event, coalesce, target]
    end
  end

  Configuration = Struct.new(:streams_presence_patterns, :streams_presence_on_change, :streams_presence_ttl,
    :streams_path, :streams_heartbeat_interval)

  module_function

  # Stub the pgbus constants for one example. `shape: :old` stubs the pre-#515
  # presence (the regression guard for the capability probe).
  def install!(example, shape: :seats)
    store = Store.new
    presence_class = shape == :old ? OldPresence : Presence
    config = Configuration.new([], nil, 60, "/pgbus/streams", 15)
    pgbus = Module.new
    pgbus.define_singleton_method(:configuration) { config }
    pgbus.define_singleton_method(:stream) do |name, durable: nil|
      _ = durable
      Stream.new(name, presence_class.new(store, name))
    end
    example.stub_const("Pgbus", pgbus)
    example.stub_const("Pgbus::Streams", Module.new)
    example.stub_const("Pgbus::Streams::Stream", Stream)
    example.stub_const("Pgbus::Streams::Presence", presence_class)
    example.stub_const("Pgbus::Streams::SignedName", Module.new do
      def self.sign(name) = "signed-#{name}"
    end)
    [store, config]
  end
end
