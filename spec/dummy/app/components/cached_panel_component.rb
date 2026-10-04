# frozen_string_literal: true

# reactive_lazy(on:, cache:) fixture (issue #277), in the DEFAULT mode (no
# reactive_cache_viewer, so the reply says Vary: Cookie): no request on page
# load; the first `panel:opened` GETs the cacheable fragment; the copy is
# reused while the cookies are unchanged — a same-page morph-back — and not on
# the next page view under the cookie session store. tag: :ul matches the real
# root so a Turbo morph keeps the element (see LazyPanelComponent).
class CachedPanelComponent < ApplicationComponent
  include Phlex::Reactive::Streamable
  include Phlex::Reactive::Component

  reactive_state :scope

  reactive_lazy on: "panel:opened", cache: { max_age: 10.minutes }, tag: :ul

  def initialize(scope: "all")
    @scope = scope
  end

  def id = "cached-panel"

  def deferred_placeholder = %(<li data-testid="cached-panel-skeleton">…</li>).html_safe

  def view_template
    ul(id:, **reactive_attrs) do
      li(data: { testid: "cached-panel-item" }) { "panel:#{@scope}" }
    end
  end
end
