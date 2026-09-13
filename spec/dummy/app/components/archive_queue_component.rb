# frozen_string_literal: true

# The async-action lifecycle demo (issue #248): a container whose action
# ENQUEUES the work instead of doing it, replies with a truthful pending state,
# and lets the job settle the row when the work actually finishes.
#
# The contrast with NotificationsListComponent is the point: `dismiss` there
# destroys the Todo and replies with the delta, because the work is synchronous.
# Here `archive` only asks for the work — so replying with a re-render would
# draw the pre-job world (the endpoint renders inside the transaction; the queue
# publishes on commit). reply.pending marks the row instead.
class ArchiveQueueComponent < ApplicationComponent
  include Phlex::Reactive::Streamable
  include Phlex::Reactive::Component

  reactive_collection :queued,
    item: NotificationRowComponent,
    container: "archive-queue",
    count: "archive-queue-count",
    empty: NotificationsEmptyComponent,
    size: -> { Todo.count }

  action :archive, params: { id: :integer }
  action :archive_all

  def id = "archive-queue-root"

  # ONE record: the job settles it, and because count == 1 the settle also tears
  # the one-shot subscription down.
  def archive(id:)
    todo = Todo.find(id)
    reply.pending(todo, in: :queued, job: ArchiveTodoJob, args: [todo.id])
      .flash(:notice, "Archiving #{todo.title}…")
  end

  # A FAN-OUT: the enqueue lives in the block, so anything ActiveJob enqueued
  # inside it — including from a service object — captures the settle handle.
  def archive_all
    todos = Todo.order(:id).to_a
    reply.pending(todos, in: :queued) do
      todos.each { ArchiveTodoJob.perform_later(it.id) }
    end.flash(:notice, "Archiving #{todos.size}…")
  end

  def view_template
    div(id:, **reactive_attrs) do
      span(id: "archive-queue-count", data: { testid: "archive-count" }) { Todo.count.to_s }

      ul(id: "archive-queue") do
        if Todo.exists?
          Todo.order(:created_at, :id).each { render NotificationRowComponent.new(todo: it) }
        else
          render NotificationsEmptyComponent.new
        end
      end

      button(**mix(on(:archive_all), data: { testid: "archive-all" })) { "Archive all" }
    end
  end
end
