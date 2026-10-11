# frozen_string_literal: true

# The templates next to the sortable-lists demo (issue #350): a SOURCE list.
# Its rows are copied into any sortable of the "tasks" group, never moved, and
# the target's action decides what lands. Client-only — no token, no actions.
class SortableTemplatesComponent < Phlex::HTML
  include Phlex::Reactive::ClientBindings

  TEMPLATES = {
    'bug' => 'Triage a bug report',
    'review' => 'Review a pull request',
    'release' => 'Cut a release'
  }.freeze

  def view_template
    div(**reactive_root(id: 'sortable-templates', class: 'flex flex-col gap-2')) do
      h3(class: 'text-sm font-semibold') { 'Templates' }
      ul(**mix(reactive_sortable_source(group: 'tasks', name: 'templates'),
               class: 'flex flex-col gap-2', data: { testid: 'sortable-templates' })) do
        TEMPLATES.each do |key, title|
          li(**mix(reactive_sortable_item(key), tabindex: -1,
                                                class: 'cursor-grab rounded-field border border-dashed border-base-300 px-3 py-2 text-sm ' \
                                                       'data-[reactive-sortable-dragging]:bg-base-100 data-[reactive-sortable-dragging]:shadow-lg',
                                                data: { testid: "template-#{key}" })) { "＋ #{title}" }
        end
      end
    end
  end
end
