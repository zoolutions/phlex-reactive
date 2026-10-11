# frozen_string_literal: true

# Issue #350: the sortable demo page — a templates source, a sortable list that
# takes drag-ins from it, and a list whose action always fails (rollback).
# Rows are 40 px tall so a spec can aim at a row's middle.
class SortablePageComponent < Phlex::HTML
  def view_template
    style do
      plain <<~CSS
        .sortable, [data-testid=templates] { list-style: none; margin: 0 0 16px; padding: 0; width: 240px; }
        .sortable li, [data-testid=templates] li { height: 40px; box-sizing: border-box; border: 1px solid #ccc; padding: 8px; background: #fff; }
        [data-reactive-sortable-placeholder] { background: #eef; }
      CSS
    end
    render SortableTemplatesComponent.new
    render SortableListComponent.new
    render SortableListComponent.new(fail: true)
  end
end
