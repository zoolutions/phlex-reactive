# frozen_string_literal: true

# Issues #274 + #276 + #277: a dormant, event-triggered, viewer-keyed cacheable
# panel — "load on first open, fetch no client until then, reuse across page
# views". The shell is dormant (no controller until `panel:opened`), the event
# wakes the root and GETs the cacheable fragment, and that fragment — fetched
# by a client that is by then loaded — renders AWAKE, so the replaced root
# needs no second wake (and the cached copy is the awake one).
class DormantCachedPanelComponent < ApplicationComponent
  include Phlex::Reactive::Streamable
  include Phlex::Reactive::Component

  # Server render count, so a spec can tell a cache hit from a re-render.
  RENDERS = Concurrent::AtomicFixnum.new

  reactive_state :scope

  reactive_lazy on: "panel:opened", cache: { max_age: 10.minutes }, tag: :ul
  reactive_dormant

  def initialize(scope: "all")
    @scope = scope
  end

  def id = "dormant-cached-panel"

  def reactive_cache_viewer = Viewer.who

  def deferred_placeholder = %(<li data-testid="dormant-cached-skeleton">…</li>).html_safe

  def view_template
    RENDERS.increment
    ul(id:, **reactive_attrs) do
      li(data: { testid: "dormant-cached-item" }) { "panel:#{@scope}:#{Viewer.who || "guest"}" }
    end
  end
end
