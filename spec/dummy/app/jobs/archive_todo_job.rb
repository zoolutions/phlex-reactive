# frozen_string_literal: true

# The job half of the issue #248 demo. Its signature is UNCHANGED by the settle:
# the handle rides ActiveJob metadata, so a nightly sweep can enqueue this same
# job with no UI attached and `reactive_settle` simply no-ops.
class ArchiveTodoJob < ActiveJob::Base
  include Phlex::Reactive::Settles

  def perform(todo_id)
    todo = Todo.find_by(id: todo_id)
    return reactive_settle { it.flash(:alert, "Todo #{todo_id} vanished") } unless todo

    todo.destroy!
    reactive_settle { it.remove(todo).flash(:notice, "Archived #{todo.title}") }
  end
end
