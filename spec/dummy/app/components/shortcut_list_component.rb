# frozen_string_literal: true

# Issue #357: a list editor with undo/redo on page-level shortcuts, a notes
# textarea beside them and a client-only palette on mod+k. The shortcuts must
# fire from the page (prevented), never from inside the textarea (its native
# text undo runs instead), and only on this platform's `mod` twin.
#
# Issue #366: Delete removes the selected row and mod+Backspace hides the
# preview — keys Stimulus's default key map lacks, so they bind a bare window
# keydown the client matches itself. Typing Delete in the search box does not.
class ShortcutListComponent < ApplicationComponent
  include Phlex::Reactive::Streamable
  include Phlex::Reactive::Component

  ROWS = %w[alpha beta gamma].freeze

  reactive_state :undos, :redos, :rows, :selected

  action :undo
  action :redo
  action :select, params: { index: :integer }
  action :remove_selected

  def initialize(undos: 0, redos: 0, rows: ROWS, selected: nil)
    @undos = undos
    @redos = redos
    @rows = rows
    @selected = selected
  end

  def id = "shortcut-list"

  def undo = @undos += 1
  def redo = @redos += 1
  def select(index:) = @selected = index

  def remove_selected
    return if @selected.nil?

    @rows = @rows.reject.with_index { |_, i| i == @selected }
    @selected = nil
  end

  def view_template
    div(**mix(reactive_root, on_client(:keydown, js.toggle("#palette"), shortcut: "mod+k"))) do
      # One reactive action per element: each shortcut on its own element.
      span(**on(:undo, shortcut: "mod+z"))
      span(**on(:redo, shortcut: "mod+shift+z"))
      span(**on(:remove_selected, shortcut: "delete"))
      span(**on_client(:keydown, js.hide("#preview"), shortcut: "mod+backspace"))
      ul(data: { testid: "list" }) { li { "first" } }
      span(data: { testid: "undos" }) { @undos.to_s }
      span(data: { testid: "redos" }) { @redos.to_s }
      textarea(name: "notes", rows: 4, data: { testid: "notes" })
      input(type: "search", name: "q", data: { testid: "search" })
      rows_list
      div(id: "preview", data: { testid: "preview" }) { "Preview" }
      div(id: "palette", hidden: true, data: { testid: "palette" }) { "Palette" }
    end
  end

  private

  def rows_list
    ul(data: { testid: "rows" }) do
      @rows.each_with_index do |row, i|
        li(aria_current: (i == @selected).to_s) do
          button(**mix(on(:select, index: i), data: { testid: "row-#{row}" })) { row }
        end
      end
    end
  end
end
