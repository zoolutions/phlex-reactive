# frozen_string_literal: true

# Issue #478: the catch-up demo page. DemosController#subscribe_catch_up
# renders it, THEN finishes the todo and broadcasts, so the broadcast is always
# sent after the render and before the browser's source connects. The marker
# outside the root shows the page was born stale; a capture listener records
# every reactive:subscribed (it does not bubble) on window.__subscribed.
class SubscribeCatchUpPageComponent < Phlex::HTML
  def initialize(todo:, replay:)
    @todo = todo
    @replay = replay
  end

  def view_template
    script(type: "module") { raw safe(%(import "pgbus/stream_source_element")) }
    script do
      raw safe(<<~JS)
        window.__subscribed = []
        document.addEventListener("reactive:subscribed", (event) => {
          window.__subscribed.push({ id: event.target.id, reconnect: event.detail.reconnect, connectionId: event.detail.connectionId })
        }, true)
      JS
    end
    p(data: { testid: "rendered-state" }) { @todo.done? ? "Done" : "Open" }
    render (@replay ? TodoReplayComponent : TodoCatchUpComponent).new(todo: @todo)
  end
end
