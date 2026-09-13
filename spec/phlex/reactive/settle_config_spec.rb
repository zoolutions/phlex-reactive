# frozen_string_literal: true

require "spec_helper"

# Issue #248 config: a settle rides a BACKGROUND JOB, which can sit behind a
# staggered fan-out for minutes — so its fallback token TTL is measured in
# minutes, not the reply->fetch gap defer_token_ttl covers.
RSpec.describe Phlex::Reactive, "settle configuration (issue #248)" do
  around do
    ttl = described_class.instance_variable_get(:@settle_token_ttl)
    window = described_class.instance_variable_get(:@settle_coalesce_window_ms)
    it.run
    described_class.instance_variable_set(:@settle_token_ttl, ttl)
    described_class.instance_variable_set(:@settle_coalesce_window_ms, window)
  end

  describe ".settle_token_ttl" do
    it "defaults to 900 seconds — distinct from defer_token_ttl" do
      expect(described_class.settle_token_ttl).to eq(900)
      expect(described_class.defer_token_ttl).to eq(120)
    end

    it "is configurable and resets to the default on nil" do
      described_class.settle_token_ttl = 60
      expect(described_class.settle_token_ttl).to eq(60)
      described_class.settle_token_ttl = nil
      expect(described_class.settle_token_ttl).to eq(900)
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
