# frozen_string_literal: true

# What Shareable is checked against (zoolutions/phlex-reactive#364).
module ShareableSpec
  # A capture-free lambda whose self (this module) is shareable: finalize! can
  # share it. A fresh one per call, so no example sees another's.
  def self.caster = -> { "#{it}!" }

  # A Hash whose default proc is capture-free, its self this module.
  def self.defaulting = Hash.new { |_, key| key.to_s }
end

# Phlex::Reactive::Shareable: the Ractor-shareable copies finalize! stores.
# It never freezes what the caller still holds, and copies keep behaving as
# the original did.
RSpec.describe Phlex::Reactive::Shareable do
  describe ".share" do
    it "shares a copy of a capture-free Proc, never freezing the caller's" do
      caster = ShareableSpec.caster

      shared = described_class.share(caster)

      expect(Ractor.shareable?(shared)).to be(true)
      expect(shared.call(1)).to eq("1!")
      expect(caster).not_to be_frozen
    end

    it "keeps a Hash's default value" do
      shared = described_class.share(Hash.new(:fallback).merge(a: +"x"))

      expect(shared[:missing]).to eq(:fallback)
      expect(Ractor.shareable?(shared)).to be(true)
    end

    it "copies a Hash with a default proc deeply, so the caller's values stay its own" do
      names = [+"a"]
      hash = Hash.new { |_, key| key.to_s }
      hash[:names] = names

      shared = described_class.share(hash)
      names << "b"

      expect(shared[:names]).to eq(["a"]).and be_frozen
      expect(shared[:other]).to eq("other")
      expect([names.frozen?, hash.frozen?]).to eq([false, false])
    end

    it "shares a Hash whose default proc can be shared" do
      shared = described_class.share(ShareableSpec.defaulting.merge(a: +"x"))

      expect(Ractor.shareable?(shared)).to be(true)
      expect(shared[:other]).to eq("other")
    end

    it "keeps a compare_by_identity Hash comparing by identity" do
      key = +"k"
      shared = described_class.share({}.compare_by_identity.merge(key => 1))

      expect(shared).to be_compare_by_identity
    end
  end

  describe ".seal_concern" do
    let(:concern) do
      Module.new do
        extend ActiveSupport::Concern

        included { nil }
      end
    end

    it "makes the concern's included block shareable" do
      described_class.seal_concern(concern)

      expect(Ractor.shareable?(concern.instance_variable_get(:@_included_block))).to be(true)
    end

    # TruffleRuby and JRuby have no Ractor; every concern in the gem calls
    # seal_concern as its body loads.
    it "leaves the concern as it is on an engine without Ractor" do
      hide_const("Ractor")

      expect(described_class.seal_concern(concern)).to be(concern)
    end
  end
end
