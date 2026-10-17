# frozen_string_literal: true

require "rails_helper"

# The engine's "phlex_reactive.routes" initializer appends the endpoint routes
# to the host app's route set. Rails main's RouteSet#finalize! makes the whole
# route set Ractor-shareable (ActiveSupport::Ractors.try_make_shareable(self)),
# append blocks included, so a block whose self is the engine made boot raise
# `Ractor::IsolationError: Proc's self is not shareable` under
# `unshareable_proc_action = :raise`. The released Rails in this bundle never
# shares the route set, so the block's own shareability is what is checked.
RSpec.describe Phlex::Reactive::Engine, "phlex_reactive.routes" do
  # A fresh route set behind the app double, so the dummy's own routes are not touched.
  let(:app) { Struct.new(:routes).new(ActionDispatch::Routing::RouteSet.new) }

  # Runs the initializer as Rails does: its block evaluated with the engine
  # instance as self and the app as the block argument.
  before do
    init = described_class.initializers.find { it.name == "phlex_reactive.routes" }
    described_class.instance.instance_exec(app, &init.block)
  end

  def appended = app.routes.instance_variable_get(:@append)

  it "appends a block Rails can make Ractor-shareable" do
    skip "Ractor.shareable_proc is Ruby 4.0+: before it no Rails shares the route set" unless
      defined?(Ractor) && Ractor.respond_to?(:shareable_proc)

    expect(appended).not_to be_empty
    expect(appended).to all(satisfy("be Ractor-shareable") { Ractor.shareable?(it) })
    expect { Ractor.make_shareable(appended.dup) }.not_to raise_error
  end

  it "still draws the endpoint routes" do
    app.routes.finalize!

    expect(app.routes.named_routes.names).to include(:phlex_reactive_action, :phlex_reactive_defer,
      :phlex_reactive_fragment)
    expect(app.routes.recognize_path(Phlex::Reactive.action_path, method: :post))
      .to include(controller: "phlex/reactive/actions", action: "create")
  end
end
