# frozen_string_literal: true

# One row of the FilteredItemsComponent list (issue #462). Keyed off a Todo so
# its #id is a stable dom_id — what reply.prepend(todo, to: :items) streams in.
class FilteredItemRowComponent < ApplicationComponent
  include Phlex::Reactive::Streamable

  def self.model_param_name = :todo

  def initialize(todo:)
    @todo = todo
  end

  def id = dom_id(@todo)

  def view_template
    li(id:, data: { testid: "filtered-item" }) { @todo.title }
  end
end
