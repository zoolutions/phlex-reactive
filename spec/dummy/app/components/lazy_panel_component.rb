# frozen_string_literal: true

# reactive_lazy(on:) fixture (issue #276): the page ships the placeholder
# shell; the real items load the first time `panel:opened` reaches the shell
# — once, through the action endpoint's `__materialize`. The "forbidden" scope
# raises a registered authorization error from the render (→ 403), the same
# contract the defer endpoint applies to a lazy component; "hidden" opts out
# via render? false.
class LazyPanelComponent < ApplicationComponent
  include Phlex::Reactive::Streamable
  include Phlex::Reactive::Component

  class Denied < StandardError; end

  reactive_state :scope

  # tag: :ul matches the real root, so a Turbo morph between the shell and the
  # real render keeps the SAME element (a tag mismatch makes idiomorph swap the
  # node instead, which is a fresh mount, not a morph).
  reactive_lazy on: "panel:opened", tag: :ul

  def initialize(scope: "all")
    @scope = scope
  end

  def id = "lazy-panel"

  def render? = @scope != "hidden"

  def deferred_placeholder = %(<li data-testid="panel-skeleton">…</li>).html_safe

  def view_template
    raise Denied, "no panel for you" if @scope == "forbidden"

    ul(id:, **reactive_attrs) do
      li(data: { testid: "panel-item" }) { "item:#{@scope}" }
    end
  end
end
