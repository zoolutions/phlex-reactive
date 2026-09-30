# frozen_string_literal: true

# The row for the pending MARKUP hook demo (issue #249). Record-backed, so it
# signs its OWN token — the case the variant subclass must not break: the
# pending markup carries a token naming this class, and the next action on the
# row has to verify.
class PendingMarkupRowComponent < ApplicationComponent
  include Phlex::Reactive::Streamable
  include Phlex::Reactive::Component

  reactive_record :todo

  action :rename, params: { title: :string }

  def initialize(todo:)
    @todo = todo
  end

  def id = dom_id(@todo)

  def rename(title:) = @todo.update!(title:)

  def view_template
    li(**mix(reactive_attrs, id:, class: "archive-row", data: { testid: "pending-markup-row" })) do
      span(class: "body") { @todo.title }
      button(data: { testid: "archive" }) { "×" }
    end
  end

  private

  # Honest pending markup: the button is GONE, not merely dimmed. The root keeps
  # the row's id (the settle targets it) and reactive_attrs (its token).
  def pending_template
    li(**mix(reactive_attrs, id:, class: "archive-row", data: { testid: "pending-markup-row" })) do
      span(class: "body") { @todo.title }
      span(class: "badge", data: { testid: "queued-badge" }) { "Queued" }
    end
  end
end
