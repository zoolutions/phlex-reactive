# frozen_string_literal: true

# What Shareable is checked against (zoolutions/phlex-reactive#364).
module ShareableSpec
  # A capture-free lambda whose self (this module) is shareable: finalize! can
  # share it. A fresh one per call, so no example sees another's.
  def self.caster = -> { "#{it}!" }

  # A Hash whose default proc is capture-free, its self this module.
  def self.defaulting = Hash.new { |_, key| key.to_s }

  # A declaration shaped like the gem's (Component::ActionDefinition).
  Definition = Data.define(:name, :params, :size)

  # A Data value whose own initialize needs more than its members, so
  # Data#with cannot rebuild it.
  Scaled = Data.define(:value) do
    def initialize(value:, scale:) = super(value: value * scale)
  end

  # A Data value whose own initialize normalizes what it is given: running
  # it again (Data#with does) would normalize twice.
  Doubled = Data.define(:value) do
    def initialize(value:) = super(value: value * 2)
  end

  # A counter whose self (this module) is shareable but which assigns the
  # variable it captures: Ractor.make_shareable raises ArgumentError for it.
  def self.counter
    calls = 0
    -> { calls += 1 }
  end
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

    it "copies a Data value with every member shared, leaving the original alone" do
      params = { title: :string, tags: [:string] }
      definition = ShareableSpec::Definition.new(name: :save, params:, size: ShareableSpec.caster)

      shared = described_class.share(definition)

      expect(Ractor.shareable?(shared)).to be(true)
      expect(shared).to have_attributes(class: ShareableSpec::Definition, name: :save, params:)
      expect(shared.size.call(2)).to eq("2!")
      expect([params.frozen?, params[:tags].frozen?, definition.size.frozen?]).to eq([false, false, false])
    end

    # Such a Proc works on the main Ractor only; sharing it must never make
    # boot raise (warm! shares every reactive_collection size: lambda).
    it "keeps a Proc that assigns a variable it captures as it is" do
      counter = ShareableSpec.counter

      expect(described_class.share(counter)).to be(counter)
      expect([counter.call, counter.call]).to eq([1, 2])
    end

    # Only Data's own initialize is safe to run again: an app's may
    # normalize, validate or need more than the members.
    it "keeps a Data value with its own initialize as it is, never running it again" do
      doubled = ShareableSpec::Doubled.new(value: [+"a"])
      scaled = ShareableSpec::Scaled.new(value: [+"a"], scale: 2)

      expect(described_class.share(doubled)).to be(doubled)
      expect(described_class.share(scaled)).to be(scaled)
      expect(doubled.value).to eq(%w[a a])
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
