# frozen_string_literal: true

# Issue #350: a sortable list, state-backed (no DB). A drop sends :move with
# item/position/after/from; a row dragged in from the templates source
# (SortableTemplatesComponent) sends :insert instead (the from: mapping). The
# reply re-renders the list in the server's order, plus the last params it got.
# `fail: true` makes :move raise, so the client's rollback can be watched.
class SortableListComponent < ApplicationComponent
  include Phlex::Reactive::Component

  class Denied < StandardError
  end

  reactive_state :tasks, :fail, :last

  action :move, params: { item: :string, position: :integer, after: :string, from: :string }
  action :insert, params: { item: :string, position: :integer, after: :string, from: :string }

  def initialize(tasks: %w[alpha bravo charlie delta], fail: false, last: "")
    @tasks = tasks
    @fail = fail
    @last = last
  end

  def id = @fail ? "sortable-fail" : "sortable"

  def move(item:, position:, after: nil, from: nil)
    raise Denied, "move refused" if @fail
    return reply.morph unless @tasks.include?(item) # a stale or forged drop adds nothing

    @tasks -= [item]
    @tasks.insert(position.clamp(0, @tasks.size), item)
    @last = "move #{item} #{position} #{after.presence || "-"} #{from}"
    reply.morph
  end

  def insert(item:, position:, after: nil, from: nil)
    @tasks = @tasks.dup.insert(position.clamp(0, @tasks.size), "#{item}-#{@tasks.size + 1}")
    @last = "insert #{item} #{position} #{after.presence || "-"} #{from}"
    reply.morph
  end

  def view_template
    div(**reactive_root(data: { testid: id })) do
      p(data: { testid: "#{id}-last" }) { @last }
      ul(**mix(reactive_sortable(:move, group: (@fail ? nil : "tasks"), from: { templates: :insert }),
        class: "sortable", data: { testid: "#{id}-list" })) do
        @tasks.each { task_row(it) }
      end
    end
  end

  private

  def task_row(task)
    li(id: "#{id}-#{task}", **mix(reactive_sortable_item(task), data: { testid: "#{id}-#{task}" })) do
      span(class: "handle") { "⠿" }
      plain " #{task}"
    end
  end
end
