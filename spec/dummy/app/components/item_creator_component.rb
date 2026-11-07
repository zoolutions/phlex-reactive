# frozen_string_literal: true

# Issue #462: the component that creates a record and tells the page. Its
# reply re-renders itself (the field clears, the count bumps) and dispatches
# app:item-created with the new item's id in the detail. It knows nothing of
# the list elsewhere on the page that hears the event: which rows that list
# shows is the list's own rule (FilteredItemsComponent).
class ItemCreatorComponent < ApplicationComponent
  include Phlex::Reactive::Streamable
  include Phlex::Reactive::Component

  reactive_state :created
  action :create, params: { title: :string }

  def initialize(created: 0)
    @created = created
  end

  def id = "item-creator"

  def create(title:)
    title = title.to_s.strip
    return reply.replace if title.blank?

    todo = Todo.create!(title:)
    @created += 1
    reply.replace.js(js.dispatch("app:item-created", detail: { id: todo.id, title: todo.title }))
  end

  def view_template
    div(id:, **reactive_attrs) do
      input(name: "title", placeholder: "New item…", autocomplete: "off", data: { testid: "new-item" })
      button(**mix(on(:create), data: { testid: "create" })) { "Add" }
      span(data: { testid: "created-count" }) { @created.to_s }
    end
  end
end
