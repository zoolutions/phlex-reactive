# frozen_string_literal: true

# Issue #357: a list editor with undo/redo on page-level shortcuts, a notes
# textarea beside them and a client-only palette on mod+k. The shortcuts must
# fire from the page (prevented), never from inside the textarea (its native
# text undo runs instead), and only on this platform's `mod` twin.
class ShortcutListComponent < ApplicationComponent
  include Phlex::Reactive::Streamable
  include Phlex::Reactive::Component

  reactive_state :undos, :redos

  action :undo
  action :redo

  def initialize(undos: 0, redos: 0)
    @undos = undos
    @redos = redos
  end

  def id = "shortcut-list"

  def undo = @undos += 1
  def redo = @redos += 1

  def view_template
    div(**mix(reactive_root, on_client(:keydown, js.toggle("#palette"), shortcut: "mod+k"))) do
      # One reactive action per element: each shortcut on its own element.
      span(**on(:undo, shortcut: "mod+z"))
      span(**on(:redo, shortcut: "mod+shift+z"))
      ul(data: { testid: "list" }) { li { "first" } }
      span(data: { testid: "undos" }) { @undos.to_s }
      span(data: { testid: "redos" }) { @redos.to_s }
      textarea(name: "notes", rows: 4, data: { testid: "notes" })
      div(id: "palette", hidden: true, data: { testid: "palette" }) { "Palette" }
    end
  end
end
