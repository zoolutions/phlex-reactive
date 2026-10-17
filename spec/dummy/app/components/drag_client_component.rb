# frozen_string_literal: true

# Issue #416: a client-only box (ClientBindings, no token, no action) whose
# fields are visible read-only inputs, so a spec can watch them follow the box.
class DragClientComponent < ApplicationComponent
  include Phlex::Reactive::ClientBindings

  def view_template
    div(**reactive_root(id: "drag-client", data: { testid: "client" })) do
      div(**mix(reactive_frame, class: "frame", data: { testid: "client-frame" })) do
        div(**mix(reactive_box(fields: { x: "area[x]", y: "area[y]", width: "area[width]", height: "area[height]" },
          value: { x: 0, y: 0, width: 0.25, height: 0.5 }), class: "box", data: { testid: "client-box" }))
      end
      { x: 0, y: 0, width: 0.25, height: 0.5 }.each do |key, value|
        input(type: "text", readonly: true, name: "area[#{key}]", value:, data: { testid: "area-#{key}" })
      end
    end
  end
end
