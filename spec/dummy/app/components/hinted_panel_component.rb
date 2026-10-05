# frozen_string_literal: true

# Issue #275: a trigger that declares an optimistic AND a busy hint, on a root
# that can be rendered dormant (reactive_dormant) and under the lazily loading
# layout — the D1 cases for the hints feature module: a live first click, a
# replayed early click, and a dormant wake, each with a hint, on a page whose
# hints module arrives late. `boom` fails (a 403) so the optimistic hint's
# rollback can be watched after a late-arriving module.
class HintedPanelComponent < ApplicationComponent
  include Phlex::Reactive::Streamable
  include Phlex::Reactive::Component

  class Denied < StandardError; end

  reactive_state :clicks, :dormant

  action :bump
  action :boom

  def initialize(clicks: 0, dormant: false)
    @clicks = clicks
    @dormant = dormant
  end

  def id = "hinted-panel"

  def bump
    sleep 0.3
    @clicks += 1
  end

  def boom
    sleep 0.3
    raise Denied, "nope"
  end

  def view_template
    attrs = @dormant ? reactive_root(dormant: true) : reactive_root
    div(**attrs) do
      button(**mix(on(:bump, optimistic: { add_class: "pressed" }, busy: "Bumping…"), data: { testid: "bump" })) { "Bump" }
      button(**mix(on(:boom, optimistic: { add_class: "pressed" }, busy: "Booming…"), data: { testid: "boom" })) { "Boom" }
      span(data: { testid: "clicks" }) { @clicks.to_s }
    end
  end
end
