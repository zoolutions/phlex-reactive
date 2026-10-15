# frozen_string_literal: true

require "rails_helper"

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
end
