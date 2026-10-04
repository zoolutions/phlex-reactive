# frozen_string_literal: true

require "spec_helper"

# Issue #273: how long a trigger captured by phlex/reactive/early before the
# controller connects stays replayable. The client reads it from
# <meta name="phlex-reactive-early-ttl" content="<%= Phlex::Reactive.early_event_ttl_ms %>">
# and falls back to the same 10 s default without the meta.
RSpec.describe Phlex::Reactive, "early event configuration (issue #273)" do
  around do
    ttl = described_class.instance_variable_get(:@early_event_ttl_ms)
    it.run
    described_class.instance_variable_set(:@early_event_ttl_ms, ttl)
  end

  it "defaults to 10 seconds, the client's own fallback" do
    expect(described_class.early_event_ttl_ms).to eq(10_000)
  end

  it "is configurable and resets to the default on nil" do
    described_class.early_event_ttl_ms = 2_500
    expect(described_class.early_event_ttl_ms).to eq(2_500)
    described_class.early_event_ttl_ms = nil
    expect(described_class.early_event_ttl_ms).to eq(10_000)
  end

  # The client treats a non-positive TTL as "use the default", so 0 could never
  # mean "drop everything": reject it where it is set, not silently on the page.
  def expect_rejected(value)
    expect { described_class.early_event_ttl_ms = value }
      .to raise_error(ArgumentError, /early_event_ttl_ms must be a positive Integer/)
  end

  it "rejects a zero, negative or non-integer TTL at assignment" do
    expect_rejected(0)
    expect_rejected(-1)
    expect_rejected(1.5)
    expect_rejected("10")
  end
end
