# frozen_string_literal: true

# Issue #416: the draggable-regions demo page — a crop box with a focal point
# (DragCropComponent) and a client-only box (DragClientComponent). Each frame
# is 400 × 200 px and the box has an outline, not a border (a border would
# shrink the padding box the point's fractions are of), so a spec can aim in
# fractions of both.
class DragPageComponent < Phlex::HTML
  def view_template
    style do
      plain <<~CSS
        .frame { position: relative; width: 400px; height: 200px; background: #ddd; margin: 0 0 16px; }
        .box { outline: 2px solid #333; background: rgb(255 255 255 / 0.3); }
        .handle { width: 12px; height: 12px; background: #333; }
        .point { width: 14px; height: 14px; border-radius: 50%; background: #c00; }
      CSS
    end
    render DragCropComponent.new
    render DragClientComponent.new
  end
end
