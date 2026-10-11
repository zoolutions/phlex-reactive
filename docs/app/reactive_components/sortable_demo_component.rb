# frozen_string_literal: true

# The sortable-lists page's live demo (issue #350): the templates source beside
# the task list. Two separate roots — the list takes drag-ins from the source
# through their shared group.
class SortableDemoComponent < Phlex::HTML
  def view_template
    div(class: 'grid gap-6 sm:grid-cols-[1fr_2fr]') do
      render SortableTemplatesComponent.new
      render SortableTasksComponent.new
    end
  end
end
