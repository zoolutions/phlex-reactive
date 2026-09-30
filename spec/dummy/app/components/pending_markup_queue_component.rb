# frozen_string_literal: true

# The container for the pending MARKUP hook demo (issue #249): ArchiveQueue's
# single-record archive, over a row that defines `pending_template`.
class PendingMarkupQueueComponent < ApplicationComponent
  include Phlex::Reactive::Streamable
  include Phlex::Reactive::Component

  reactive_collection :queued,
    item: PendingMarkupRowComponent,
    container: "pending-markup-queue",
    size: -> { Todo.count }

  action :archive, params: { id: :integer }

  def id = "pending-markup-queue-root"

  def archive(id:)
    todo = Todo.find(id)
    reply.pending(todo, in: :queued, job: ArchiveTodoJob, args: [todo.id])
  end

  def view_template
    div(id:, **reactive_attrs) do
      ul(id: "pending-markup-queue") do
        Todo.order(:created_at, :id).each { render PendingMarkupRowComponent.new(todo: it) }
      end
    end
  end
end
