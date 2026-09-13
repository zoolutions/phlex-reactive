# frozen_string_literal: true

# The row for the async-action lifecycle demo (issue #248).
#
# It exists instead of reusing NotificationRowComponent because that row's ×
# dispatches `dismiss` — an action ArchiveQueueComponent does not declare (it
# archives asynchronously; it never deletes synchronously). Sharing the row
# would render a visible control that 403s on click, which is exactly the kind
# of default-deny surprise the demo is supposed to teach away from.
class ArchiveRowComponent < ApplicationComponent
  include Phlex::Reactive::Streamable
  include Phlex::Reactive::Component

  def self.model_param_name = :todo

  def initialize(todo:)
    @todo = todo
  end

  def id = dom_id(@todo)

  def view_template
    li(id:, class: "archive-row", data: { testid: "archive-row" }) do
      span(class: "body") { @todo.title }
      button(**mix(on(:archive, id: @todo.id), data: { testid: "archive" })) { "×" }
    end
  end
end
