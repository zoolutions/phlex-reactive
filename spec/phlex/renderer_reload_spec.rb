# frozen_string_literal: true

require "rails_helper"

# Phlex::Reactive.renderer after a code reload (zoolutions/phlex-reactive#364).
# A renderer given as a Class is that class object for good: after Zeitwerk
# reloads it in development, re-renders and broadcasts keep running the old,
# unloaded class. Given by name (like base_controller_name), it resolves on
# every read and follows the reload.
RSpec.describe Phlex::Reactive, ".renderer across a code reload" do
  around do
    original = described_class.renderer
    it.run
  ensure
    described_class.renderer = original
    described_class.reset_stream_builder!
  end

  # A Zeitwerk (re)load: a new class object under the same name.
  def define_controller = stub_const("RendererReloadSpecController", Class.new(ActionController::Base))

  # What a reload does to the constant, then the engine's to_prepare.
  def reload!
    define_controller
    Phlex::Reactive::Streamable.reset_all_view_contexts!
    described_class.reset_stream_builder!
  end

  it "follows the reloaded class when it is set by name" do
    define_controller
    described_class.renderer = "RendererReloadSpecController"
    before_reload = described_class.off_request_view_context.controller.class

    reload!

    expect(described_class.renderer).to be(RendererReloadSpecController)
    expect(described_class.renderer).not_to be(before_reload)
    expect(described_class.off_request_view_context.controller).to be_an_instance_of(RendererReloadSpecController)
  end

  it "keeps the name through finalize!" do
    define_controller
    described_class.renderer = "RendererReloadSpecController"

    described_class.finalize!
    reload!

    expect(described_class.renderer).to be(RendererReloadSpecController)
  end

  it "keeps a class it was given as that class object" do
    stale = define_controller
    described_class.renderer = stale

    reload!

    expect(described_class.renderer).to be(stale)
  end
end
