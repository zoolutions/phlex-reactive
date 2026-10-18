# frozen_string_literal: true

# Issue #429: the reproduction — a box that drags inside a 400 × 200 px frame,
# in the same root as an `esc` shortcut (:close). Escape during a drag
# (keyboard or pointer) cancels the drag and calls preventDefault, so :close
# skips that key; the `handled: true` shortcut (:leave) runs anyway. With no
# drag, one Escape runs both. The box has no action: a drag sends nothing, so
# every request is a shortcut's.
class DragShortcutComponent < ApplicationComponent
  include Phlex::Reactive::Component

  BOX = { x: 0.1, y: 0.1, width: 0.5, height: 0.4 }.freeze

  reactive_state :closes, :leaves

  action :close
  action :leave

  def initialize(closes: 0, leaves: 0)
    @closes = closes
    @leaves = leaves
  end

  def id = "drag-shortcut"

  def close = @closes += 1
  def leave = @leaves += 1

  def view_template
    div(**reactive_root) do
      span(**on(:close, shortcut: "esc"))
      span(**on(:leave, shortcut: { keys: "esc", handled: true }))
      p(data: { testid: "closes" }) { "closes #{@closes}" }
      p(data: { testid: "leaves" }) { "leaves #{@leaves}" }
      div(**mix(reactive_frame, class: "frame", data: { testid: "frame" })) do
        div(**mix(box, class: "box", data: { testid: "box" }, aria: { label: "Box" }))
      end
      BOX.each { |key, value| input(type: "hidden", name: "box[#{key}]", value:) }
    end
  end

  private

  def box = reactive_box(fields: BOX.to_h { |key, _| [key, "box[#{key}]"] }, value: BOX)
end
