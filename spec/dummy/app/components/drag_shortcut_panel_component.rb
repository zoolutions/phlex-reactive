# frozen_string_literal: true

# Issue #429: a client-only root beside DragShortcutComponent whose on_client
# `esc` shortcut shows a panel — the runOps path of the handled-key skip. It
# is its own root so the server roots' re-renders never reset the panel.
class DragShortcutPanelComponent < ApplicationComponent
  include Phlex::Reactive::ClientBindings

  def view_template
    div(**mix(reactive_root(id: "drag-shortcut-panel"), on_client(:keydown, js.show("#esc-panel"), shortcut: "esc"))) do
      div(id: "esc-panel", hidden: true, data: { testid: "esc-panel" }) { "Escaped" }
    end
  end
end
