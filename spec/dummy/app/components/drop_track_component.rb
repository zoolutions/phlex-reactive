# frozen_string_literal: true

# Issue #433: on(..., prevent: false). A server trigger on a drop zone keeps
# the drop's native default: the browser still delivers the dropped file to
# the native file input inside it, and the :track round trip still runs (the
# re-render shows the count). The input has no name, so the round trip never
# collects it.
class DropTrackComponent < ApplicationComponent
  include Phlex::Reactive::Streamable
  include Phlex::Reactive::Component

  reactive_state :drops

  action :track

  def initialize(drops: 0)
    @drops = drops
  end

  def id = "drop-track"

  def track
    @drops += 1
  end

  def view_template
    div(**reactive_root) do
      div(**mix(
        on(:track, event: "drop", prevent: false),
        style: "position: relative; width: 320px; height: 120px; border: 2px dashed",
        data: { testid: "track-zone" }
      )) do
        input(type: "file", data: { testid: "track-input" },
          style: "position: absolute; inset: 0; width: 100%; height: 100%; opacity: 0")
        plain "Drop a file here (server trigger): drops "
        span(data: { testid: "drops" }) { @drops.to_s }
      end
    end
  end
end
