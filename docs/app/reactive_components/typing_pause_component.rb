# frozen_string_literal: true

# Issue #393: on_client takes debounce:/throttle: like on. Two bindings on one
# input compose through mix: the plain one runs on every keystroke, the
# debounced one once, 500 ms after the last. No actions, no round trips.
class TypingPauseComponent < Phlex::HTML
  include Phlex::Reactive::Component

  def id = 'typing-pause'

  def view_template
    div(**mix(reactive_root, class: 'flex flex-col gap-2 max-w-sm')) do
      input(type: 'search', placeholder: 'Type, then stop', class: 'input input-bordered',
            **mix(on_client(:input, js.text('#tp-status', 'Typing…')),
                  on_client(:input, js.text('#tp-status', 'Paused: this ran once, 500 ms after the last key'),
                            debounce: 500)))
      span(id: 'tp-status', class: 'text-sm opacity-70') { 'Waiting for input' }
    end
  end
end
