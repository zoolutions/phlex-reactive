# frozen_string_literal: true

require "rails_helper"
require_relative "../../support/fake_pgbus_presence"

# Issue #358: every pgbus touchpoint of presence goes through
# Phlex::Reactive::Presence::Transport. The capability is a probe of the real
# method signatures (#515's connection-keyed join, set_state, the change hook),
# never a version string, and the boot hook is a no-op without it — an app on
# Action Cable boots exactly as before.
RSpec.describe Phlex::Reactive::Presence::Transport do
  describe ".capable?" do
    it "is false without pgbus" do
      skip "pgbus is loaded in this process" if defined?(Pgbus)
      expect(described_class.capable?).to be(false)
    end

    it "is false for a pgbus whose presence is keyed by member (pre-#515)" do
      FakePgbusPresence.install!(self, shape: :old)
      expect(described_class.capable?).to be(false)
    end

    # pgbus 0.17.3 has seats but fires pgbus:connected before the seat joins
    # and has no streams_authorize for the engine mount: presence needs 0.18.
    it "is false for pgbus 0.17.3 (seats, but no streams_authorize)" do
      FakePgbusPresence.install!(self, shape: :v017)
      expect(described_class.wired?).to be(false)
      expect(described_class.capable?).to be(false)
    end

    it "is false when the configuration has no change hook" do
      FakePgbusPresence.install!(self)
      # Everything else wired? reads is present: only the hook WRITER is missing.
      no_writer = Class.new do
        attr_accessor :streams_presence_patterns, :streams_presence_ttl, :streams_authorize
        attr_reader :streams_presence_on_change
      end
      allow(Pgbus).to receive(:configuration).and_return(no_writer.new)
      expect(described_class.capable?).to be(false)
    end

    it "is false while the seat table is not migrated" do
      FakePgbusPresence.install!(self)
      allow(Pgbus::Streams::Presence).to receive(:seats_supported?).and_return(false)
      expect(described_class.capable?).to be(false)
    end

    it "is true for the connection-keyed shape" do
      FakePgbusPresence.install!(self)
      expect(described_class.capable?).to be(true)
    end
  end

  describe ".install!" do
    it "does nothing without the capability" do
      skip "pgbus is loaded in this process" if defined?(Pgbus)
      expect { Phlex::Reactive::Presence.install! }.not_to raise_error
    end

    it "touches nothing on a pgbus whose presence is keyed by member" do
      _store, config = FakePgbusPresence.install!(self, shape: :old)
      Phlex::Reactive::Presence.install!
      expect(config.streams_presence_patterns).to eq([])
      expect(config.streams_presence_on_change).to be_nil
    end

    it "adds the presence pattern once and chains an existing change hook" do
      _store, config = FakePgbusPresence.install!(self)
      seen = []
      config.streams_presence_on_change = ->(name, change) { seen << [name, change[:type]] }
      allow(Phlex::Reactive::PresenceRenderJob).to receive(:perform_later)

      Phlex::Reactive::Presence.install!
      Phlex::Reactive::Presence.install!

      expect(config.streams_presence_patterns).to eq([described_class::PATTERN])
      config.streams_presence_on_change.call("board_1:presence:viewers", { type: :join })
      expect(seen).to eq([["board_1:presence:viewers", :join]])
      expect(Phlex::Reactive::PresenceRenderJob).to have_received(:perform_later).once.with("board_1:presence:viewers")
    end

    # pgbus >= 0.19 deep-freezes its plain-data settings at boot
    # (Configuration#finalize!, zoolutions/pgbus#527); only a setter may change one.
    it "adds the pattern through the setter when pgbus froze the list" do
      _store, config = FakePgbusPresence.install!(self)
      config.streams_presence_patterns = ["chat:lobby"].freeze

      expect { Phlex::Reactive::Presence.install! }.not_to raise_error
      expect(config.streams_presence_patterns).to eq(["chat:lobby", described_class::PATTERN])
    end

    it "only enqueues for presence streams" do
      _store, config = FakePgbusPresence.install!(self)
      allow(Phlex::Reactive::PresenceRenderJob).to receive(:perform_later)
      Phlex::Reactive::Presence.install!

      config.streams_presence_on_change.call("board_1:cards", { type: :join })
      expect(Phlex::Reactive::PresenceRenderJob).not_to have_received(:perform_later)
    end
  end

  # Boot and class load must never touch the database: `rails db:create` and
  # `assets:precompile` run them before one exists. Only seats_supported? (a
  # query) needs it, so it is reached from a render and the job alone.
  describe "without a database" do
    before do
      FakePgbusPresence.install!(self)
      allow(Pgbus::Streams::Presence).to receive(:seats_supported?)
        .and_raise(ActiveRecord::NoDatabaseError, 'FATAL: database "app" does not exist')
    end

    it "boots: install! registers the pattern and the hook without a query" do
      expect { Phlex::Reactive::Presence.install! }.not_to raise_error
      expect(Pgbus.configuration.streams_presence_patterns).to eq([described_class::PATTERN])
      expect(Pgbus::Streams::Presence).not_to have_received(:seats_supported?)
    end

    it "loads a presence component and registers its ttl without a query" do
      expect do
        Class.new(Phlex::HTML) do
          include Phlex::Reactive::Component

          def self.name = "BootRoster"

          reactive_record :board
          reactive_presence :lobby, ttl: 20
        end
      end.not_to raise_error
      expect(Pgbus.configuration.streams_presence_ttl).to include(/:presence:lobby\z/ => 20)
      expect(Pgbus::Streams::Presence).not_to have_received(:seats_supported?)
    end

    it "lets the error surface at render (no silent false)" do
      expect { described_class.capable? }.to raise_error(ActiveRecord::NoDatabaseError)
    end
  end

  describe ".wired?" do
    it "is the signature probe alone: true on an unmigrated #515 pgbus" do
      FakePgbusPresence.install!(self)
      allow(Pgbus::Streams::Presence).to receive(:seats_supported?).and_return(false)
      expect(described_class.wired?).to be(true)
      expect(described_class.capable?).to be(false)
    end

    it "is false for the old member-keyed shape" do
      FakePgbusPresence.install!(self, shape: :old)
      expect(described_class.wired?).to be(false)
    end
  end

  describe ".register_ttl" do
    it "writes the seconds under the stream-name pattern, keeping an Integer setting as the default" do
      _store, config = FakePgbusPresence.install!(self)
      described_class.register_ttl(:viewers, 30)
      expect(config.streams_presence_ttl).to eq(default: 60, /:presence:viewers\z/ => 30)
      expect(config.streams_presence_ttl.keys.last.match?("board_1:presence:viewers")).to be(true)
    end

    it "adds to an app's Hash setting" do
      _store, config = FakePgbusPresence.install!(self)
      config.streams_presence_ttl = { "lobby" => 30, default: 90 }
      described_class.register_ttl(:viewers, 45)
      expect(config.streams_presence_ttl).to eq("lobby" => 30, :default => 90, /:presence:viewers\z/ => 45)
    end

    # pgbus >= 0.19 freezes an app's Hash at boot (Configuration#finalize!,
    # zoolutions/pgbus#527), and a component that loads later (eager_load off)
    # still registers its ttl.
    it "adds to an app's Hash setting that pgbus froze at boot" do
      _store, config = FakePgbusPresence.install!(self)
      config.streams_presence_ttl = { "lobby" => 30, default: 90 }.freeze

      expect { described_class.register_ttl(:viewers, 45) }.not_to raise_error
      expect(config.streams_presence_ttl).to eq("lobby" => 30, :default => 90, /:presence:viewers\z/ => 45)
    end

    it "replaces a component's earlier ttl when its class loads again" do
      _store, config = FakePgbusPresence.install!(self)
      described_class.register_ttl(:viewers, 30)
      config.streams_presence_ttl.freeze

      described_class.register_ttl(:viewers, 45)
      expect(config.streams_presence_ttl).to eq(default: 60, /:presence:viewers\z/ => 45)
    end
  end
end
