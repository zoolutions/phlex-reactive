# frozen_string_literal: true

# Issue #303: TWO roots sharing one window-bound hotkey (`k`), as a page with
# a hotkey-driven sidebar and a hotkey-driven palette has. /hotkey_pair renders
# a pair: ?dormant=both (the default) makes both dormant, ?dormant=second
# leaves the first awake (its controller connects on load) and the second
# dormant. One press before connect must reach each root exactly once, and a
# root's replay must never swallow its sibling's live firing. `o` is a :once
# hotkey on the first root, for the end-to-end :once case.
class HotkeyPairComponent < ApplicationComponent
  include Phlex::Reactive::Streamable
  include Phlex::Reactive::Component

  reactive_state :name, :keys, :onces

  action :press
  action :press_once

  def initialize(name:, dormant: true, keys: 0, onces: 0)
    @name = name
    @dormant = dormant
    @keys = keys
    @onces = onces
  end

  def id = "hotkey-#{@name}"

  def press = @keys += 1

  # A MORPH keeps the root element — and Stimulus's still-armed `once` listener
  # for the replayed hotkey — in place: the case a replay must keep spent.
  def press_once
    @onces += 1
    reply.morph
  end

  def view_template
    div(**mix(reactive_root(dormant: @dormant), { data: { testid: "root-#{@name}" } })) do
      span(**on(:press, event: "keydown.k", window: true))
      span(**on(:press_once, event: "keydown.o", window: true, once: true)) if @name == "first"
      span(data: { testid: "keys-#{@name}" }) { @keys.to_s }
      span(data: { testid: "onces-#{@name}" }) { @onces.to_s }
    end
  end
end
