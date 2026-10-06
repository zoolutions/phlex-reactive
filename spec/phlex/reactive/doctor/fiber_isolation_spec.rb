# frozen_string_literal: true

require "rails_helper"

# Falcon serves each request as a fiber on one thread. Under Rails' default
# `config.active_support.isolation_level = :thread`, every piece of thread-keyed
# state (CurrentAttributes, IsolatedExecutionState, the transactional-test
# connection lock, Thread.current) is shared by the requests on that thread
# (issue #321). The doctor fails Falcon + :thread with the one-line fix, passes
# Falcon + :fiber and any other server, and is advisory when it cannot tell
# which server serves the app.
RSpec.describe Phlex::Reactive::Doctor do
  subject(:doctor) { described_class.new }

  describe "#fiber_isolation_check" do
    it "fails Falcon under :thread isolation, with the one-line fix" do
      check = doctor.fiber_isolation_check(server: "falcon", isolation: :thread)

      expect(check).to be_fail
      expect(check.name).to eq(:fiber_isolation)
      expect(check.message).to include("Falcon", ":thread")
      expect(check.fix).to include("config.active_support.isolation_level = :fiber")
    end

    it "passes Falcon under :fiber isolation" do
      check = doctor.fiber_isolation_check(server: "falcon", isolation: :fiber)

      expect(check).to be_ok
      expect(check.message).to include(":fiber")
    end

    it "passes Puma under :thread isolation (a thread per request)" do
      check = doctor.fiber_isolation_check(server: "puma", isolation: :thread)

      expect(check).to be_ok
      expect(check.message).to include("puma")
    end

    it "passes :thread isolation when Falcon is not in the bundle" do
      expect(doctor.fiber_isolation_check(server: :none, isolation: :thread)).to be_ok
    end

    it "is advisory when the server cannot be detected, naming the setting" do
      check = doctor.fiber_isolation_check(server: nil, isolation: :thread)

      expect(check).to be_unknown
      expect(check.fix).to include("config.active_support.isolation_level = :fiber")
    end

    it "passes an undetectable server under :fiber isolation (safe either way)" do
      expect(doctor.fiber_isolation_check(server: nil, isolation: :fiber)).to be_ok
    end
  end

  describe ".detect_server" do
    it "is the only server in the bundle" do
      expect(described_class.detect_server(bundled: %w[falcon], loaded: [])).to eq("falcon")
      expect(described_class.detect_server(bundled: %w[puma], loaded: [])).to eq("puma")
    end

    it "is the only server loaded when the bundle has several" do
      expect(described_class.detect_server(bundled: %w[falcon puma], loaded: %w[falcon])).to eq("falcon")
      expect(described_class.detect_server(bundled: %w[falcon puma], loaded: %w[puma])).to eq("puma")
    end

    it "cannot tell (nil) when Falcon is bundled beside another server and neither is singled out" do
      expect(described_class.detect_server(bundled: %w[falcon puma], loaded: [])).to be_nil
      expect(described_class.detect_server(bundled: %w[falcon puma], loaded: %w[falcon puma])).to be_nil
    end

    it "is :none when no Falcon is anywhere and no single server stands out" do
      expect(described_class.detect_server(bundled: [], loaded: [])).to eq(:none)
      expect(described_class.detect_server(bundled: %w[puma unicorn], loaded: [])).to eq(:none)
    end

    it "reads the bundle from Gem.loaded_specs (this repo bundles both falcon and puma)" do
      expect(described_class.bundled_servers).to include("falcon", "puma")
    end

    it "never requires falcon to find out" do
      skip "Falcon already loaded by another spec" if defined?(Falcon)

      described_class.detect_server
      doctor.checks
      expect(defined?(Falcon)).to be_nil
    end
  end

  describe "#checks" do
    # The dummy bundles Falcon AND Puma and sets :fiber only under
    # CAPYBARA_SERVER=falcon, so it is advisory or ok here — never a failure.
    it "includes the fiber-isolation check, never failing the dummy app" do
      check = doctor.checks.find { it.name == :fiber_isolation }

      expect(check).not_to be_nil
      expect(check).not_to be_fail
    end

    it "reads the live isolation level" do
      allow(ActiveSupport::IsolatedExecutionState).to receive(:isolation_level).and_return(:fiber)

      expect(doctor.checks.find { it.name == :fiber_isolation }).to be_ok
    end
  end
end
