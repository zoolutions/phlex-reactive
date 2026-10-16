# frozen_string_literal: true

require "spec_helper"

# What Phlex::Reactive.finalize! is checked against (zoolutions/phlex-reactive#364).
module FinalizeSpec
  # A capture-free caster defined in a module body: its self (this module) is
  # shareable, so finalize! can share it.
  MONEY = -> { it.to_s.match?(/\A\d+\z/) ? it.to_i : Phlex::Reactive::ParamSchema::DROP }

  class Denied < StandardError; end

  # Every configuration reader, except the verifier (see its own example).
  def self.readers = Phlex::Reactive::CONFIG_READERS.map { Phlex::Reactive.method(it) }
end

# Tier 3 of conformance-kit: after finalize! (the engine calls it once boot is
# over) every configuration reader returns a Ractor-shareable value, so a
# non-main Ractor can read it; writers keep working.
RSpec.describe Phlex::Reactive, ".finalize!" do
  # finalize! replaces the module's settings with frozen copies: put the
  # originals back so no other example sees them.
  around do
    snapshot = described_class.instance_variables.to_h { [it, described_class.instance_variable_get(it)] }
    it.run
  ensure
    (described_class.instance_variables - snapshot.keys).each { described_class.remove_instance_variable(it) }
    snapshot.each { |ivar, value| described_class.instance_variable_set(ivar, value) }
  end

  context "with the defaults" do
    before do
      described_class.reset_finalization!
      described_class.reset_param_types!
      described_class.reset_param_schemas!
      described_class.reset_around_actions!
      described_class.reset_on_action_error!
      described_class.reset_token_upgraders!
    end

    it_behaves_like "a boot-finalized configuration", readers: FinalizeSpec.readers,
      finalize: -> { described_class.finalize! }
  end

  context "with an app's settings" do
    before do
      described_class.reset_finalization!
      described_class.reset_param_types!
      described_class.reset_param_schemas!
      described_class.action_path = +"/app/reactive"
      described_class.base_controller_name = +"ApplicationController"
      described_class.authorization_errors = [FinalizeSpec::Denied]
      described_class.authorization_methods = %i[authorize! policy_check]
      described_class.flash_target = +"notices"
      described_class.defer_transport = "fetch"
      described_class.early_event_ttl_ms = 5_000
      described_class.effects = { enter: :fade, update: :highlight }
      described_class.param_type(:money, &FinalizeSpec::MONEY)
      described_class.param_schema(:todo, title: :string, tags: [:string], address: { street: :string })
    end

    it_behaves_like "a boot-finalized configuration", readers: FinalizeSpec.readers,
      finalize: -> { described_class.finalize! }

    it "keeps every value" do
      described_class.finalize!

      expect(described_class.action_path).to eq("/app/reactive")
      expect(described_class.base_controller_name).to eq("ApplicationController")
      expect(described_class.flash_target).to eq("notices")
      expect(described_class.early_event_ttl_ms).to eq(5_000)
      expect(described_class.authorization_errors).to eq([FinalizeSpec::Denied])
      expect(described_class.authorization_methods).to eq(%i[authorize! policy_check])
      expect(described_class.defer_transport).to eq(:fetch)
      expect(described_class.param_schema(:todo)).to eq(title: :string, tags: [:string], address: { street: :string })
      expect(described_class.param_types.fetch(:money).call("12")).to eq(12)
    end

    it "never freezes the app's own objects" do
      errors = [FinalizeSpec::Denied]
      path = +"/mine"
      described_class.authorization_errors = errors
      described_class.action_path = path

      described_class.finalize!

      expect([errors.frozen?, path.frozen?]).to eq([false, false])
      expect(described_class.authorization_errors).to be_frozen
    end
  end

  describe "the collections an app appends to at boot" do
    before { described_class.reset_finalization! }

    it "are open until finalize! and frozen after it" do
      described_class.authorization_errors = []
      described_class.authorization_errors << FinalizeSpec::Denied

      described_class.finalize!

      expect(described_class.authorization_errors).to eq([FinalizeSpec::Denied]).and be_frozen
      expect { described_class.authorization_errors << StandardError }.to raise_error(FrozenError)
    end
  end

  describe "writers after finalize!" do
    before do
      described_class.reset_finalization!
      described_class.finalize!
    end

    it "keep working, and what they write is shareable too" do
      described_class.authorization_errors = [FinalizeSpec::Denied]
      described_class.defer_path = +"/later"

      expect(described_class.authorization_errors).to eq([FinalizeSpec::Denied])
      expect(Ractor.shareable?(described_class.authorization_errors)).to be(true)
      expect(Ractor.shareable?(described_class.defer_path)).to be(true)
    end

    it "keep registering around_action wrappers" do
      described_class.reset_around_actions!
      described_class.around_action { |_ctx, &action| action.call }

      expect(described_class.around_actions.size).to eq(1)
    end
  end

  describe "values that cannot be shared" do
    before do
      described_class.reset_finalization!
      described_class.reset_param_types!
      described_class.reset_around_actions!
    end

    # A block written in a spec (or an initializer) has a self that is not
    # shareable: it is kept as it is and keeps working on the main Ractor,
    # inside a frozen list.
    it "keeps an app's Proc working, frozen but main-only" do
      described_class.param_type(:upcase) { it.to_s.upcase }
      described_class.around_action { |_ctx, &action| action.call }

      described_class.finalize!

      expect(described_class.param_types).to be_frozen
      expect(described_class.param_types.fetch(:upcase).call("a")).to eq("A")
      expect(described_class.around_actions).to be_frozen
      expect(Ractor.shareable?(described_class.around_actions)).to be(false)
    end

    it "leaves the verifier as built: an ActiveSupport::MessageVerifier is never shareable" do
      verifier = ActiveSupport::MessageVerifier.new("finalize-spec-secret")
      described_class.verifier = verifier

      described_class.finalize!

      expect(described_class.verifier).to be(verifier)
      expect(verifier).not_to be_frozen
    end
  end

  describe ".finalized? and .reset_finalization!" do
    it "reports the state, and reopens what finalize! froze" do
      described_class.reset_finalization!
      expect(described_class.finalized?).to be(false)

      described_class.finalize!
      described_class.finalize!
      expect(described_class.finalized?).to be(true)

      described_class.reset_finalization!
      expect(described_class.finalized?).to be(false)
      expect { described_class.authorization_errors << FinalizeSpec::Denied }.not_to raise_error
    end
  end
end
