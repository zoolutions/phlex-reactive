# frozen_string_literal: true

# Editable text (issue #351): a root whose FIRST reactive_editable arrives
# later, appended by a stream — not by a morph of the root. The root itself
# carries no bindings marker, so at connect it never asked for the bindings
# feature; the appended editable's Enter/Escape/paste handling must still be
# there once it is focused (on the split client: the module is imported then,
# or already started by the stream that brought the editable).
class LateEditableComponent < ApplicationComponent
  include Phlex::Reactive::Streamable
  include Phlex::Reactive::Component

  reactive_state :seed
  action :add

  def initialize(seed: "late")
    @seed = seed
  end

  def id = "late-editable"

  # A token-only refresh plus the append: the root is not re-rendered, so it
  # stays connected and never re-reads its markers.
  def add = reply.streams(LateEditableTitleComponent.append(target: "late-slot"))

  def view_template
    div(**reactive_root) do
      button(**mix(on(:add), data: { testid: "add" })) { "Add a title" }
      div(id: "late-slot")
    end
  end
end
