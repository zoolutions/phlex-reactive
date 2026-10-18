# frozen_string_literal: true

# Issue #429: Escape shortcuts beside a draggable box (DragShortcutComponent)
# and a client-only root's on_client Escape (DragShortcutPanelComponent).
class DragShortcutPageComponent < Phlex::HTML
  def view_template
    style do
      plain <<~CSS
        .frame { position: relative; width: 400px; height: 200px; background: #ddd; margin: 0 0 16px; }
        .box { outline: 2px solid #333; background: rgb(255 255 255 / 0.3); }
      CSS
    end
    render DragShortcutComponent.new
    render DragShortcutPanelComponent.new
  end
end
