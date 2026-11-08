# frozen_string_literal: true

# Issue #462: a list that hears app:item-created from anywhere on the page and
# decides ITSELF whether the new item belongs in it. The root is the trigger:
# on(:show_new_item, event: "app:item-created", window: true,
# detail_params: { id: :id }) posts the detail's id as the action's `id`
# param, typed by the schema like any other param. The action looks the item
# up and prepends its row only when the title matches the list's own filter —
# a rule that lives here, in the list's reactive state, not in a CSS selector
# the creating component would have to know. A miss is a token-only refresh
# (reply.streams), so the list stays as it is.
class FilteredItemsComponent < ApplicationComponent
  include Phlex::Reactive::Streamable
  include Phlex::Reactive::Component

  reactive_state :filter
  reactive_collection :items, item: FilteredItemRowComponent, container: "filtered-items"
  action :show_new_item, params: { id: :integer }

  def initialize(filter: nil)
    @filter = filter
  end

  def id = "filtered-items-list"

  def show_new_item(id:)
    todo = Todo.find(id)
    return reply.streams unless matches?(todo)

    reply.prepend(todo, to: :items)
  end

  def view_template
    div(id:, **mix(reactive_attrs, on(:show_new_item, event: "app:item-created", window: true, detail_params: { id: :id }))) do
      p(data: { testid: "filter" }) { @filter.present? ? "Showing: #{@filter}" : "Showing everything" }
      ul(id: "filtered-items") do
        matching.order(id: :desc).each { render FilteredItemRowComponent.new(todo: it) }
      end
    end
  end

  private

  def matching
    return Todo.all if @filter.blank?

    Todo.where("LOWER(title) LIKE ?", "%#{Todo.sanitize_sql_like(@filter.downcase)}%")
  end

  def matches?(todo) = @filter.blank? || todo.title.downcase.include?(@filter.downcase)
end
