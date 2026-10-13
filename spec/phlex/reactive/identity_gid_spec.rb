# frozen_string_literal: true

require "rails_helper"

# The signed gid of a record-backed component. For a record whose to_gid is
# GlobalID's own and whose id is an Integer, the string is built directly
# instead of through a validated URI::GID; it must be byte-identical to
# record.to_gid.to_s, and everything else must still go through to_gid.
RSpec.describe Phlex::Reactive::Component, "#reactive_identity_payload's gid" do
  let(:component_class) do
    Class.new(Phlex::HTML) do
      include Phlex::Reactive::Component

      def self.name = "IdentityGidSpecRow"

      reactive_record :record

      def initialize(record:) = (@record = record)
      def id = "identity-gid-spec"
    end
  end

  def gid_of(record) = component_class.new(record:).send(:reactive_identity_payload)["gid"]

  # A plain GlobalID-able model in a namespace: the gid carries "Outer::Thing".
  before do
    stub_const("IdentityGidSpec::Thing", Class.new do
      include GlobalID::Identification

      attr_reader :id

      def initialize(id) = (@id = id)
      def self.find(id) = new(id)
    end)
  end

  describe "a record whose to_gid is GlobalID's own and whose id is an Integer" do
    it "matches to_gid for real records" do
      todos = Array.new(3) { Todo.create!(title: "gid #{it}") }

      todos.each { expect(gid_of(it)).to eq(it.to_gid.to_s) }
    end

    it "matches to_gid for a namespaced class and zero, negative and large ids" do
      [0, -7, 1, 2**62].each do
        thing = IdentityGidSpec::Thing.new(it)
        expect(gid_of(thing)).to eq(thing.to_gid.to_s)
      end
    end

    it "matches to_gid under another GlobalID.app" do
      original = GlobalID.app
      GlobalID.app = "My-Other.app"
      thing = IdentityGidSpec::Thing.new(42)

      expect(gid_of(thing)).to eq(thing.to_gid.to_s)
      expect(gid_of(thing)).to start_with("gid://My-Other.app/")
    ensure
      GlobalID.app = original
    end

    it "does not build a URI::GID" do
      thing = IdentityGidSpec::Thing.new(5)
      allow(URI::GID).to receive(:create).and_call_original

      gid_of(thing)

      expect(URI::GID).not_to have_received(:create)
    end
  end

  describe "anything else goes through to_gid" do
    before { allow(URI::GID).to receive(:create).and_call_original }

    it "a String id (it may need escaping)" do
      thing = IdentityGidSpec::Thing.new("a b+c")

      expect(gid_of(thing)).to eq(thing.to_gid.to_s)
      expect(URI::GID).to have_received(:create).at_least(:once)
    end

    it "a composite id" do
      thing = IdentityGidSpec::Thing.new([1, 2])

      expect(gid_of(thing)).to eq(thing.to_gid.to_s)
    end

    it "a class that overrides to_gid" do
      klass = Class.new(IdentityGidSpec::Thing) do
        def self.name = "IdentityGidSpec::Custom"
        def to_gid(...) = GlobalID.new("gid://custom/Elsewhere/#{id}")
      end

      expect(gid_of(klass.new(3))).to eq("gid://custom/Elsewhere/3")
    end

    it "a single record whose to_gid is overridden on the instance" do
      thing = IdentityGidSpec::Thing.new(9)
      thing.define_singleton_method(:to_gid) { |*| GlobalID.new("gid://custom/Mine/9") }

      expect(gid_of(thing)).to eq("gid://custom/Mine/9")
    end

    it "an object that is not GlobalID-able (to_gid's own NoMethodError)" do
      expect { gid_of(Object.new) }.to raise_error(NoMethodError, /to_gid/)
    end

    it "an unset GlobalID.app (to_gid's own error)" do
      original = GlobalID.app
      GlobalID.instance_variable_set(:@app, nil)

      expect { gid_of(IdentityGidSpec::Thing.new(1)) }.to raise_error(ArgumentError, /An app is required/)
    ensure
      GlobalID.app = original
    end
  end
end
