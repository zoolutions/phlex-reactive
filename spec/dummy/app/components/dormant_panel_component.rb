# frozen_string_literal: true

# Issue #274: a DORMANT root — it renders data-reactive-dormant="reactive"
# instead of data-controller="reactive", so the reactive controller is neither
# mounted nor (on the lazily loading layout) fetched until one of its triggers
# fires. The root also carries an app controller ("probe"), which must stay
# connected through the wake.
class DormantPanelComponent < ApplicationComponent
  include Phlex::Reactive::Streamable
  include Phlex::Reactive::Component

  reactive_state :clicks, :loads
  reactive_dormant

  action :bump
  action :load
  action :bump_and_broadcast

  def initialize(clicks: 0, loads: 0)
    @clicks = clicks
    @loads = loads
  end

  def id = "dormant-panel"

  def bump = @clicks += 1

  # An EXPLICIT reply renders inside the action body — awake all the same. The
  # morph keeps the root element (already awake on the page) in place.
  def load
    @loads += 1
    reply.morph
  end

  # The actor's reply is awake; the broadcast other tabs receive stays dormant.
  def bump_and_broadcast
    @clicks += 1
    self.class.broadcast_to("dormant", replace: self.class.new(clicks: @clicks, loads: @loads))
  end

  # The app controller is listed BEFORE reactive_root: waking appends "reactive"
  # to data-controller, so the awake reply ("probe reactive") matches what the
  # page already has and a morph reply reconnects nothing.
  def view_template
    div(**mix({ data: { controller: "probe" } }, reactive_root, on(:load, event: "panel:opened", once: true))) do
      button(**mix(on(:bump), data: { testid: "bump" })) { "Bump" }
      span(data: { testid: "clicks" }) { @clicks.to_s }
      span(data: { testid: "loads" }) { @loads.to_s }
    end
  end
end
