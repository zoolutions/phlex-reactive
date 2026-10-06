# frozen_string_literal: true

# Issue #273: the triggers phlex/reactive/early must capture before a lazily
# loaded controller connects — a button click, a link click (whose native
# navigation must be prevented) and a :once custom event on the root. Issue
# #303 adds two window-bound hotkeys — `k` (a server action) and `j` (an
# on_client toggle) — pressed anywhere on the page.
class EarlyTriggersComponent < ApplicationComponent
  include Phlex::Reactive::Streamable
  include Phlex::Reactive::Component

  reactive_state :clicks, :loads, :keys

  action :bump
  action :load
  action :press

  def initialize(clicks: 0, loads: 0, keys: 0)
    @clicks = clicks
    @loads = loads
    @keys = keys
  end

  def id = "early-triggers"

  def bump = @clicks += 1

  def press = @keys += 1

  # A MORPH keeps the root element (and Stimulus's still-armed `once` listener)
  # in place — the case where a replayed :once trigger could fire again.
  def load
    @loads += 1
    reply.morph
  end

  def view_template
    div(**mix(reactive_root, on(:load, event: "panel:opened", once: true))) do
      button(**mix(on(:bump), data: { testid: "bump" })) { "Bump" }
      a(**mix(on(:bump), href: "/counter", data: { testid: "link" })) { "Bump (link)" }
      span(data: { testid: "clicks" }) { @clicks.to_s }
      span(data: { testid: "loads" }) { @loads.to_s }
      span(**mix(on(:press, event: "keydown.k", window: true), data: { testid: "keys" })) { @keys.to_s }
      span(**on_client("keydown.j", js.toggle("#early-hint"), window: true))
      p(id: "early-hint", hidden: true, data: { testid: "hint" }) { "Hotkey hint" }
    end
  end
end
