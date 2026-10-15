# frozen_string_literal: true

require "rails_helper"

# Ractor mode needs eager loading and a finalized configuration whose every
# setting a non-main Ractor can read (zoolutions/phlex-reactive#364). The
# doctor reports what stands in the way, advisory only: no app is required to
# run Ractors, and Rails, ActiveSupport and Phlex still block it upstream.
RSpec.describe Phlex::Reactive::Doctor, "#ractor_readiness_check" do
  subject(:doctor) { described_class.new }

  def check(eager_load: true, finalized: true, unshareable: {})
    doctor.ractor_readiness_check(eager_load:, finalized:, unshareable:)
  end

  it "is ok when phlex-reactive's side is ready, naming the upstream blockers" do
    result = check

    expect(result).to be_ok
    expect(result.name).to eq(:ractor_readiness)
    expect(result.message).to include("finalized", "yippee-fun/phlex#1055", "MessageVerifier")
  end

  it "is advisory without eager loading" do
    result = check(eager_load: false)

    expect(result).to be_unknown
    expect(result.message).to include("eager loading is off")
    expect(result.fix).to include("config.eager_load = true")
  end

  it "is advisory when the configuration is not finalized" do
    result = check(finalized: false)

    expect(result).to be_unknown
    expect(result.fix).to include("Phlex::Reactive.finalize!")
  end

  it "names each setting a non-main Ractor cannot read, and the value's class" do
    result = check(unshareable: { around_actions: Array, error_flash: Proc })

    expect(result).to be_unknown
    expect(result.message).to include("2 settings", "around_actions (Array)", "error_flash (Proc)")
    expect(result.fix).to include("capture-free lambda")
  end

  it "never fails the doctor" do
    results = [check(eager_load: false), check(finalized: false), check(unshareable: { apm: Object })]

    expect(results.none?(&:fail?)).to be(true)
  end

  describe ".unshareable_settings" do
    around do
      original = Phlex::Reactive.around_actions
      it.run
    ensure
      Phlex::Reactive.reset_around_actions!
      original.each { Phlex::Reactive.around_action(&it) }
    end

    it "lists the settings whose value is not Ractor-shareable, never the verifier" do
      Phlex::Reactive.finalize!
      Phlex::Reactive.around_action { |_ctx, &action| action.call }

      expect(described_class.unshareable_settings).to include(around_actions: Array)
      expect(described_class.unshareable_settings).not_to have_key(:verifier)
    end
  end

  it "is part of the doctor's report" do
    expect(doctor.checks.map(&:name)).to include(:ractor_readiness)
  end
end
