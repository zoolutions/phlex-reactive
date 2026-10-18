# frozen_string_literal: true

# Issue #433: on_client(..., prevent: false). Two drop zones, each a native
# <input type="file"> stretched over an area, with a "dragging over"
# highlight: `kept` clears it on drop with prevent: false, so the browser
# still delivers the dropped file to the input (its `change` writes
# "received"); `prevented` clears it with the default, so the drop is
# cancelled and the input stays empty. Declares no actions (client-op only).
class DropZoneComponent < ApplicationComponent
  include Phlex::Reactive::Component

  def id = "drop-zones"

  def view_template
    div(**reactive_root) do
      zone("kept", prevent: false)
      zone("prevented")
    end
  end

  private

  def zone(name, **drop)
    div(**mix(
      on_client(:dragenter, js.add_class("#dz-#{name}", "is-over")),
      on_client(:drop, js.remove_class("#dz-#{name}", "is-over"), **drop),
      id: "dz-#{name}", style: "position: relative; width: 320px; height: 120px; border: 2px dashed",
      data: { testid: "#{name}-zone" }
    )) do
      input(**mix(on_client(:change, js.text("#dz-#{name}-status", "received")),
        type: "file", name: name, data: { testid: "#{name}-input" },
        style: "position: absolute; inset: 0; width: 100%; height: 100%; opacity: 0"))
      plain "Drop a file here (#{name}): "
      span(id: "dz-#{name}-status", data: { testid: "#{name}-status" }) { "empty" }
    end
  end
end
