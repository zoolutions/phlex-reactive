# frozen_string_literal: true

require "spec_helper"

# Issue #248 config. NOTE what is deliberately ABSENT: the issue's sketch had a
# `settle_token_ttl` for a fallback pull token, but a settle has no pull lane —
# the client cannot poll "is the job done yet", and redeeming such a token at the
# defer endpoint would render the PRE-JOB component (the exact bug reply.pending
# fixes). A setting that cannot change behavior is worse than no setting.
RSpec.describe Phlex::Reactive, "settle configuration (issue #248)" do
  around do
    window = described_class.instance_variable_get(:@settle_coalesce_window_ms)
    it.run
    described_class.instance_variable_set(:@settle_coalesce_window_ms, window)
  end

  describe "the absence of a settle token TTL" do
    it "exposes no settle_token_ttl — a settle has no pull lane for a token to govern" do
      expect(described_class).not_to respond_to(:settle_token_ttl)
    end

    it "still exposes defer_token_ttl, which governs a lane that really exists" do
      expect(described_class.defer_token_ttl).to eq(120)
    end
  end

  describe ".settle_coalesce_window_ms" do
    it "defaults to 50ms" do
      expect(described_class.settle_coalesce_window_ms).to eq(50)
    end

    it "is configurable and resets to the default on nil" do
      described_class.settle_coalesce_window_ms = 200
      expect(described_class.settle_coalesce_window_ms).to eq(200)
      described_class.settle_coalesce_window_ms = nil
      expect(described_class.settle_coalesce_window_ms).to eq(50)
    end
  end

  describe ".settle_capable?" do
    it "is false without the defer push lane — a settle has no pull fallback" do
      allow(described_class).to receive(:defer_push_capable?).and_return(false)
      expect(described_class.settle_capable?).to be(false)
    end

    it "is false when defer_transport forces :fetch — :fetch is not a settle lane" do
      allow(described_class).to receive_messages(defer_push_capable?: true, defer_transport: :fetch)
      expect(described_class.settle_capable?).to be(false)
    end

    it "is true with the push lane available and the transport not forced to :fetch" do
      allow(described_class).to receive_messages(defer_push_capable?: true, defer_transport: :auto)
      expect(described_class.settle_capable?).to be(true)
    end
  end
end
