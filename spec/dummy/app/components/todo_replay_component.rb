# frozen_string_literal: true

# Issue #478: a component on a DURABLE stream ([todo, :replay] matches the
# dummy's streams_durable_patterns). Its root carries the watermark at render,
# so its source replays a broadcast sent before it connected. No refresh
# action: the catch-up must come from the replay alone.
class TodoReplayComponent < ApplicationComponent
  include Phlex::Reactive::Component

  reactive_record :todo
  reactive_subscribe :replay

  def initialize(todo:)
    @todo = todo
  end

  def id = "todo-replay-#{@todo.id}"

  def view_template
    div(**reactive_root(data: { testid: "todo-replay" })) do
      span(data: { testid: "todo-replay-state" }) { @todo.done? ? "Done" : "Open" }
    end
  end
end
