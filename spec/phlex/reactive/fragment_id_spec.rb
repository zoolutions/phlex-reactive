# frozen_string_literal: true

require "rails_helper"

# The fragment id's encoding (issue #306). The id is
#   base64url(JSON payload) + base64url(128-bit keyed MAC)
# — the payload encoded ONCE, where the previous format wrapped the
# verifier's whole token (Base64 JSON + "--" + hex digest) in a second Base64.
# Ids minted in the previous format still verify: a browser may hold a cached
# page or fragment URL for up to fragment_cache_max_age_limit. The new format
# is tried first, then the old.
RSpec.describe Phlex::Reactive::Fragment do
  let(:payload) { { "c" => "CachedPanelComponent", "s" => { "scope" => "mine" } } }

  # An id exactly as the previous release minted it.
  def legacy_id(data = payload)
    token = Phlex::Reactive.verifier.generate(data.merge("v" => Phlex::Reactive::TOKEN_VERSION),
      purpose: described_class::PURPOSE)
    Base64.urlsafe_encode64(token, padding: false)
  end

  describe ".sign" do
    subject(:id) { described_class.sign(payload) }

    it "is one URL path segment of base64url characters" do
      expect(id).to match(/\A[A-Za-z0-9_-]+\z/)
    end

    it "encodes the payload once, followed by a 22-character MAC" do
      data = id[0...-22]

      expect(JSON.parse(Base64.urlsafe_decode64(data))).to eq(payload.merge("v" => Phlex::Reactive::TOKEN_VERSION))
      expect(id.length - data.length).to eq(22)
    end

    it "is deterministic, so the browser's cache can key on it" do
      expect(described_class.sign(payload)).to eq(id)
    end

    it "is much shorter than the previous format" do
      expect(id.length).to be < legacy_id.length / 2
    end

    it "changes with the signing secret" do
      original = Phlex::Reactive.verifier
      id # minted under the original secret
      Phlex::Reactive.verifier = ActiveSupport::MessageVerifier.new("another-secret-" * 4)

      expect(described_class.sign(payload)).not_to eq(id)
    ensure
      Phlex::Reactive.verifier = original
    end
  end

  describe ".verify" do
    it "round-trips a new id" do
      expect(described_class.verify(described_class.sign(payload))).to include(payload)
    end

    it "still verifies an id minted in the previous format" do
      expect(described_class.verify(legacy_id)).to include(payload)
    end

    it "upgrades either format's payload (the token version is inside the signed data)" do
      [described_class.sign(payload), legacy_id].each do
        expect(described_class.verify(it)).to include("v" => Phlex::Reactive::TOKEN_VERSION)
      end
    end

    describe "tampering (new format)" do
      let(:id) { described_class.sign(payload) }
      let(:data) { id[0...-22] }
      let(:mac) { id[-22..] }

      def encode(hash) = Base64.urlsafe_encode64(JSON.generate(hash), padding: false)

      it "rejects a swapped payload under the original MAC" do
        swapped = encode(payload.merge("c" => "CachedMenuComponent", "v" => 1))

        expect(described_class.verify("#{swapped}#{mac}")).to be_nil
      end

      it "rejects a flipped MAC character" do
        flipped = mac.sub(/\A./) { it == "A" ? "B" : "A" }

        expect(described_class.verify("#{data}#{flipped}")).to be_nil
      end

      it "rejects a truncated id" do
        expect(described_class.verify(id[0...-1])).to be_nil
        expect(described_class.verify(mac)).to be_nil
      end

      it "rejects a MAC computed with another secret" do
        other = ActiveSupport::MessageVerifier.new("another-secret-" * 4)
        original = Phlex::Reactive.verifier
        Phlex::Reactive.verifier = other
        foreign = described_class.sign(payload)
        Phlex::Reactive.verifier = original

        expect(described_class.verify(foreign)).to be_nil
      ensure
        Phlex::Reactive.verifier = original
      end

      it "rejects a valid MAC over data that is not a JSON object" do
        array = Base64.urlsafe_encode64("[1,2]", padding: false)

        expect(described_class.verify("#{array}#{described_class.send(:compact_mac, array)}")).to be_nil
      end
    end

    describe "tampering (previous format)" do
      it "rejects a swapped class under the original digest" do
        token = Base64.urlsafe_decode64(legacy_id)
        data, digest = token.split("--")
        swapped = Base64.strict_encode64(Base64.decode64(data).sub("CachedPanelComponent", "CachedMenuComponent"))

        expect(described_class.verify(Base64.urlsafe_encode64("#{swapped}--#{digest}", padding: false))).to be_nil
      end

      it "rejects a reversed id" do
        expect(described_class.verify(legacy_id.reverse)).to be_nil
      end
    end

    it "rejects identity and defer tokens, wrapped or bare" do
      identity = Phlex::Reactive.sign(payload)
      defer = Phlex::Reactive.sign_defer(payload, unbound: true)

      [identity, defer].each do
        expect(described_class.verify(it)).to be_nil
        expect(described_class.verify(Base64.urlsafe_encode64(it, padding: false))).to be_nil
      end
    end

    it "is never accepted as an identity or a defer token" do
      id = described_class.sign(payload)

      expect(Phlex::Reactive.verify(id)).to be_nil
      expect(Phlex::Reactive.verify_defer(id)).to be_nil
    end

    # The id arrives as a UTF-8 param while it was minted as a US-ASCII
    # string; a Marshal-serializing verifier (load_defaults < 7.1) signs the
    # encoding along with the bytes, so the MAC must not depend on it.
    it "verifies an id that arrives with another string encoding, under a Marshal-serializing verifier" do
      original = Phlex::Reactive.verifier
      Phlex::Reactive.verifier = ActiveSupport::MessageVerifier.new("marshal-secret-" * 4, serializer: Marshal)
      id = described_class.sign(payload)

      [id, id.dup.force_encoding(Encoding::UTF_8), id.b].each do
        expect(described_class.verify(it)).to include(payload)
      end
    ensure
      Phlex::Reactive.verifier = original
    end

    it "is nil for an id with characters outside base64url (never raises)" do
      ["#{"é" * 30}#{"a" * 22}", "#{"\xFF".b * 30}#{"a" * 22}", "a b+c/#{"a" * 22}"].each do
        expect(described_class.verify(it)).to be_nil
      end
    end

    it "is nil for garbage" do
      ["", "***", "a" * 22, nil, "x.y"].each { expect(described_class.verify(it)).to be_nil }
    end
  end

  describe ".version_param" do
    it "is 64 bits as 11 base64url characters" do
      expect(described_class.version_param("abc")).to match(/\A[A-Za-z0-9_-]{11}\z/)
    end
  end

  describe ".viewer_param" do
    it "is 128 bits as 22 base64url characters" do
      expect(described_class.viewer_param(42)).to match(/\A[A-Za-z0-9_-]{22}\z/)
    end
  end
end
