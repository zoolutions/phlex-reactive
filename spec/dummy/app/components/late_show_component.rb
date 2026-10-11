# frozen_string_literal: true

# Issue #356: a root whose FIRST reactive_show target arrives later, appended
# by a stream — not by a morph of the root. The root carries no bindings
# marker, so at connect it never asked for the bindings feature; the appended
# target must still be seeded from the field and follow it.
class LateShowComponent < ApplicationComponent
  include Phlex::Reactive::Streamable
  include Phlex::Reactive::Component

  reactive_state :seed
  action :add

  def initialize(seed: "late")
    @seed = seed
  end

  def id = "late-show"

  # A token-only refresh plus the append: the root is not re-rendered, so it
  # stays connected and only a stream re-read finds the new marker.
  def add = reply.streams(LateShowPanelComponent.append(target: "late-show-slot"))

  def view_template
    div(**reactive_root) do
      label do
        plain "Mode "
        select(name: "mode", data: { testid: "mode" }) do
          option(value: "basic") { "Basic" }
          option(value: "pro") { "Pro" }
        end
      end
      button(**mix(on(:add), data: { testid: "add" })) { "Add the pro panel" }
      div(id: "late-show-slot")
    end
  end
end
