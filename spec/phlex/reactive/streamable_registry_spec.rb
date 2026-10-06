# frozen_string_literal: true

require "rails_helper"

# Issue #302: the Streamable registry is what the inventory (phlex_reactive:actions,
# phlex_reactive:find, the MCP tools), the doctor and the reload hook iterate. It
# was populated only from Streamable's `included` hook, so a SUBCLASS of a
# reactive component — which inherits the mixin rather than including it — never
# entered it.
RSpec.describe Phlex::Reactive::Streamable, "registry" do
  let(:registered) { described_class.registered_classes }

  it "registers a subclass of a reactive component" do
    sub = Class.new(PublicCounterComponent)
    expect(registered).to include(sub)
  end

  it "registers a subclass of a subclass" do
    grandchild = Class.new(Class.new(PublicCounterComponent))
    expect(registered).to include(grandchild)
  end

  it "registers the eager-loaded dummy subclass" do
    Rails.application.eager_load!
    expect(registered.map(&:name)).to include("InheritedSkipComponent")
  end

  it "flushes a subclass's memoized view context on reload (reset_all_view_contexts!)" do
    sub = Class.new(PublicCounterComponent)
    expect { described_class.reset_all_view_contexts! }
      .to change(sub, :turbo_view_context_generation).by(1)
  end
end
