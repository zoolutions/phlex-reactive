# frozen_string_literal: true

# Issue #273: the triggers phlex/reactive/early must capture before a lazily
# loaded controller connects — a button click, a link click (whose native
# navigation must be prevented) and a :once custom event on the root.
class EarlyTriggersComponent < ApplicationComponent
  include Phlex::Reactive::Streamable
  include Phlex::Reactive::Component

  reactive_state :clicks, :loads

  action :bump
  action :load

  def initialize(clicks: 0, loads: 0)
    @clicks = clicks
    @loads = loads
  end

  def id = "early-triggers"

  def bump = @clicks += 1

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
    end
  end
end
