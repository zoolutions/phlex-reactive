# frozen_string_literal: true

# The sortable-lists demo (issue #350): a task list you reorder by dragging a
# row's ⠿ handle (mouse, touch or pen) or with the keyboard, and that takes
# copies of the templates next to it (SortableTemplatesComponent). The order
# lives in signed state — no database — so every visitor gets their own list.
class SortableTasksComponent < Phlex::HTML
  include Phlex::Reactive::Streamable
  include Phlex::Reactive::Component

  TASKS = ['Write the failing spec', 'Make it pass', 'Refactor', 'Open the pull request'].freeze
  MAX_TASKS = 10

  # The drag's styling hooks: the list while a drag is over it, the dragged
  # row, and the placeholder gap where it would land.
  LIST_CSS = 'flex min-h-24 flex-col gap-2 rounded-box p-1 ' \
             'data-[reactive-sortable-active]:bg-base-200 ' \
             '[&>[data-reactive-sortable-placeholder]]:rounded-field ' \
             '[&>[data-reactive-sortable-placeholder]]:border-2 ' \
             '[&>[data-reactive-sortable-placeholder]]:border-dashed ' \
             '[&>[data-reactive-sortable-placeholder]]:border-primary/50'
  ROW_CSS = 'flex items-center gap-3 rounded-field border border-base-300 bg-base-100 px-3 py-2 ' \
            'focus:outline-2 focus:outline-primary ' \
            'data-[reactive-sortable-dragging]:shadow-lg data-[reactive-sortable-dragging]:ring-2 ' \
            'data-[reactive-sortable-dragging]:ring-primary'

  reactive_state :tasks

  # A reorder sends the row's key and its new index; a template dragged in
  # sends the template's key (the from: mapping picks :insert for it).
  action :move, params: { item: :string, position: :integer }
  action :insert, params: { item: :string, position: :integer }

  def initialize(tasks: TASKS)
    @tasks = tasks
  end

  def id = 'sortable-tasks'

  def move(item:, position:)
    return reply.morph unless @tasks.include?(item)

    @tasks -= [item]
    @tasks.insert(position.clamp(0, @tasks.size), item)
    reply.morph
  end

  def insert(item:, position:)
    title = SortableTemplatesComponent::TEMPLATES[item]
    return reply.morph if title.nil? || @tasks.size >= MAX_TASKS

    @tasks = @tasks.dup.insert(position.clamp(0, @tasks.size), unique(title))
    reply.morph
  end

  def view_template
    div(**reactive_root(class: 'flex flex-col gap-2', data: { testid: 'sortable-tasks' })) do
      h3(class: 'text-sm font-semibold') { "Tasks (#{@tasks.size})" }
      ol(**mix(reactive_sortable(:move, group: 'tasks', handle: '[data-drag-handle]',
                                        from: { templates: :insert }),
               class: LIST_CSS, data: { testid: 'sortable-tasks-list' })) do
        @tasks.each { task_row(it) }
      end
    end
  end

  private

  def task_row(task)
    li(id: "task-#{task.parameterize}", class: ROW_CSS, **reactive_sortable_item(task)) do
      span(class: 'cursor-grab touch-none select-none opacity-50', data: { drag_handle: true }) { '⠿' }
      span { task }
    end
  end

  # A second copy of a template gets a number, so every row keeps its own key.
  def unique(title)
    return title unless @tasks.include?(title)

    (2..).lazy.map { "#{title} (#{it})" }.find { @tasks.exclude?(it) }
  end
end
