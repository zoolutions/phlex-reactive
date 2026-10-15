# frozen_string_literal: true

require "rails_helper"
require "logger"
require "stringio"

module BootFinalizationSpec
  # An app's APM adapter: an object holding a Logger, which no Ractor can share.
  class Apm
    attr_reader :logger

    def initialize(logger) = @logger = logger
    def record_action(*) = nil
    def record_error(*) = nil
  end
end

# The engine finalizes the configuration once the app has booted
# (zoolutions/phlex-reactive#364): after every initializer AND every
# after_initialize block the app registered, so a block that appends to a
# setting (the dummy's config/initializers/phlex_reactive.rb does) still runs
# against an open configuration.
RSpec.describe Phlex::Reactive::Engine, "boot finalization" do
  it "finalizes the configuration at boot" do
    expect(Phlex::Reactive.finalized?).to be(true)
  end

  it "runs after the app's own after_initialize blocks" do
    expect(Phlex::Reactive.authorization_errors).to include(CounterComponent::Denied, CachedMenuComponent::Denied)
    expect(Phlex::Reactive.authorization_errors).to be_frozen
  end

  it "is registered after the app's config/initializers are loaded" do
    names = Rails.application.initializers.tsort.map { it.name.to_s }

    expect(names.index("phlex_reactive.finalize")).to be > names.rindex("load_config_initializers")
  end

  it "freezes every registry an app registers into at boot, with no call of its own" do
    expect([Phlex::Reactive.param_types_frozen?, Phlex::Reactive.param_schemas_frozen?]).to eq([true, true])
    expect([Phlex::Reactive.param_types, Phlex::Reactive.around_actions, Phlex::Reactive.on_action_error_hooks,
            Phlex::Reactive.token_upgraders]).to all(be_frozen)
  end

  # What the boot hook (finalize_boot!) does with values no Ractor can share:
  # it finalizes anyway and keeps each one as it is, working on the main
  # Ractor, so nothing an app's initializer sets can make boot raise.
  describe "with values no Ractor can share" do
    let(:reactive) { Phlex::Reactive }

    # finalize! replaces the module's settings with frozen copies: put the
    # originals back so no other example sees them.
    around do
      snapshot = reactive.instance_variables.to_h { [it, reactive.instance_variable_get(it)] }
      it.run
    ensure
      (reactive.instance_variables - snapshot.keys).each { reactive.remove_instance_variable(it) }
      snapshot.each { |ivar, value| reactive.instance_variable_set(ivar, value) }
    end

    before do
      reactive.reset_finalization!
      reactive.reset_param_types!
      reactive.reset_around_actions!
      reactive.reset_on_action_error!
    end

    it "boots with an initializer's closures, a logger and an APM object, and keeps each one working" do
      reports = []
      logger = Logger.new(StringIO.new)
      apm = BootFinalizationSpec::Apm.new(logger)
      reactive.on_action_error do |error, _ctx|
        reports << error
        logger.warn(error.message)
      end
      reactive.around_action { |_ctx, &action| action.call }
      reactive.error_flash = -> { it == :forbidden ? "No." : "Oops." }
      reactive.importmaps = -> { { "application" => logger } }
      reactive.apm = apm
      reactive.param_type(:upcase) { it.to_s.upcase }

      expect { described_class.finalize_boot!(eager_load: false) }.not_to raise_error
      expect(reactive.finalized?).to be(true)

      reactive.on_action_error_hooks.each { it.call(RuntimeError.new("boom"), {}) }
      expect(reports.map(&:message)).to eq(["boom"])
      expect([reports, logger, apm].map(&:frozen?)).to eq([false, false, false])
      expect(reactive.apm).to be(apm)
      expect(reactive.error_flash.call(:forbidden)).to eq("No.")
      expect(reactive.importmaps.call).to eq("application" => logger)
      expect(reactive.param_types.fetch(:upcase).call("a")).to eq("A")
      expect(Ractor.shareable?(reactive.action_path)).to be(true)
    end

    # A production rake task or build step can boot without a secret_key_base.
    # The verifier was built on first use before boot finalized it; boot must
    # not start raising where it did not, so the first token raises instead.
    it "boots without a secret_key_base, leaving the verifier to raise on first use" do
      missing = ArgumentError.new("Missing `secret_key_base` for 'production' environment")
      allow(Rails.application).to receive(:message_verifier).and_raise(missing)
      reactive.verifier = nil

      expect { described_class.finalize_boot!(eager_load: false) }.not_to raise_error
      expect(reactive.finalized?).to be(true)
      expect { reactive.verifier }.to raise_error(ArgumentError, /secret_key_base/)
    end
  end
end
