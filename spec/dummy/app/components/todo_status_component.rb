# frozen_string_literal: true

# Issue #474: a component that subscribes to its own broadcast stream. The
# root carries the signed src of [todo, :status]; FinishTodoJob broadcasts the
# finished todo with broadcast_self, and no view renders a turbo_stream_from.
class TodoStatusComponent < ApplicationComponent
  include Phlex::Reactive::Component

  reactive_record :todo
  reactive_subscribe :status

  def initialize(todo:)
    @todo = todo
  end

  def id = "todo-status-#{@todo.id}"

  def view_template
    div(**reactive_root(data: { testid: "todo-status" })) do
      span(data: { testid: "todo-status-title" }) { @todo.title }
      span(data: { testid: "todo-status-state" }) { @todo.done? ? "Done" : "Open" }
    end
  end
end
