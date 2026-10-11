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

    it "is false when the configuration has no change hook" do
      FakePgbusPresence.install!(self)
      stub_const("FakePgbusPresence::Configuration", Struct.new(:streams_presence_patterns))
      allow(Pgbus).to receive(:configuration).and_return(Struct.new(:streams_presence_patterns).new([]))
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

    it "only enqueues for presence streams" do
      _store, config = FakePgbusPresence.install!(self)
      allow(Phlex::Reactive::PresenceRenderJob).to receive(:perform_later)
      Phlex::Reactive::Presence.install!

      config.streams_presence_on_change.call("board_1:cards", { type: :join })
      expect(Phlex::Reactive::PresenceRenderJob).not_to have_received(:perform_later)
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
  end
end
