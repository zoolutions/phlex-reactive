# frozen_string_literal: true

# Issue #478: a component on an EPHEMERAL stream, which has no archive to
# replay. It refetches itself on reactive:subscribed, which the client
# dispatches on the root each time its source connects.
class TodoCatchUpComponent < ApplicationComponent
  include Phlex::Reactive::Component

  reactive_record :todo
  reactive_subscribe :catch_up
  action :refresh

  def initialize(todo:)
    @todo = todo
  end

  def id = "todo-catch-up-#{@todo.id}"

  # The implicit reply re-renders the root from the reloaded record.
  def refresh; end

  def view_template
    div(**mix(reactive_root(data: { testid: "todo-catch-up" }), on(:refresh, event: "reactive:subscribed"))) do
      span(data: { testid: "todo-catch-up-state" }) { @todo.done? ? "Done" : "Open" }
    end
  end
end
