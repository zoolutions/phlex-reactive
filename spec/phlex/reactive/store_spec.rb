# frozen_string_literal: true

# Phlex::Reactive::Store (zoolutions/phlex-reactive#364): per-Ractor lazy
# state, the home for the caches that used to live in Concurrent::Map
# constants. Ractor.store_if_absent where the engine has it, else one
# Mutex-guarded table (an engine without Ractors has only the one).
RSpec.describe Phlex::Reactive::Store do
  # Ractor-local storage cannot be deleted, so every example uses its own key.
  let(:key) { :"phlex_reactive_store_spec_#{SecureRandom.hex(6)}" }

  describe ".fetch" do
    it "builds the value once and returns the same object afterwards" do
      calls = 0
      first = described_class.fetch(key) do
        calls += 1
        Object.new
      end

      expect(described_class.fetch(key) { raise "rebuilt" }).to be(first)
      expect(calls).to eq(1)
    end

    it "needs an initializer block" do
      expect { described_class.fetch(key) }.to raise_error(ArgumentError, /initializer block/)
    end

    context "when threads race to build the value" do
      let(:subject_call) do
        store_key = key
        -> { described_class.fetch(store_key) { Thread.pass && Object.new } }
      end

      it_behaves_like "thread-safe under contention", threads: 8, iterations: 20, consistent: :identical
    end

    context "without Ractor.store_if_absent (an engine with no Ractors)" do
      before do
        allow(described_class).to receive(:native?).and_return(false)
        stub_const("Phlex::Reactive::Store::FALLBACK", Phlex::Reactive::Store::Table.new)
      end

      it "memoizes in the fallback table" do
        first = described_class.fetch(key) { Object.new }

        expect(described_class.fetch(key) { raise "rebuilt" }).to be(first)
        expect(Phlex::Reactive::Store::FALLBACK.fetch(key) { raise "missing" }).to be(first)
      end
    end

    it "keeps no table of its own where Ractor.store_if_absent exists" do
      skip "this engine has no Ractor.store_if_absent" unless described_class.native?

      expect(Phlex::Reactive::Store::FALLBACK).to be_nil
    end

    it "gives a non-main Ractor its own value", :ractor do
      skip "needs Ruby 4.0+ (Ractor#value)" unless defined?(Ractor) && Ractor.method_defined?(:value)

      main = described_class.fetch(key) { +"main" }
      # A Ractor block is isolated: it cannot call the example's described_class.
      inside = Ractor.new(key) { Phlex::Reactive::Store.fetch(it) { +"inside" } }.value # rubocop:disable RSpec/DescribedClass

      expect(inside).to eq("inside")
      expect(described_class.fetch(key) { +"rebuilt" }).to be(main)
    end
  end

  describe ".table" do
    it "is one Table per key in this Ractor" do
      expect(described_class.table(key)).to be_a(Phlex::Reactive::Store::Table)
        .and be(described_class.table(key))
    end
  end

  describe Phlex::Reactive::Store::Table do
    subject(:table) { described_class.new }

    it "computes a missing value once" do
      calls = 0
      2.times { table.fetch(:a) { calls += 1 } }

      expect(table.fetch(:a) { raise "rebuilt" }).to eq(1)
      expect(calls).to eq(1)
    end

    it "claims a key exactly once until cleared" do
      expect([table.claim?(:x), table.claim?(:x), table.claim?(:y)]).to eq([true, false, true])

      table.clear

      expect(table.claim?(:x)).to be(true)
    end

    context "when threads race to claim one key" do
      let(:subject_call) do
        shared = described_class.new
        -> { shared.claim?(:once) }
      end

      it "lets exactly one of them win" do
        claims = Array.new(8) { Thread.new { Array.new(20) { subject_call.call } } }.flat_map(&:value)

        expect(claims.count(true)).to eq(1)
      end
    end
  end
end
