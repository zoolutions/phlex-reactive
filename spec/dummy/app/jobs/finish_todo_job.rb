# frozen_string_literal: true

# Issue #474: the job half of the subscribe demo. It finishes the todo and
# broadcasts the component to its declared stream; the open page receives it
# through the subscription the component rendered itself.
class FinishTodoJob < ActiveJob::Base
  def perform(todo_id)
    todo = Todo.find(todo_id)
    todo.update!(done: true)
    TodoStatusComponent.broadcast_self(replace: todo)
  end
end
