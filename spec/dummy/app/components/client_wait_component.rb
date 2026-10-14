# frozen_string_literal: true

# Issue #393: debounce:/throttle: on on_client. Each trigger dispatches a
# bubbling CustomEvent the system spec counts, so "ran once after the burst"
# and "ran on the first event, then dropped" are observable without a fetch.
# Declares no actions (client-op only — zero round trips).
class ClientWaitComponent < ApplicationComponent
  include Phlex::Reactive::Component

  def id = "client-wait"

  def view_template
    div(**reactive_root) do
      input(type: "search", **mix(
        on_client(:input, js.dispatch("cw:debounced", to: :root), debounce: 300),
        data: { testid: "debounced" }
      ))
      input(type: "text", **mix(
        on_client(:input, js.dispatch("cw:throttled", to: :root), throttle: 600),
        data: { testid: "throttled" }
      ))
      input(type: "text", **mix(
        on_client(:input, js.dispatch("cw:every", to: :root)),
        data: { testid: "every" }
      ))
    end
  end
end
