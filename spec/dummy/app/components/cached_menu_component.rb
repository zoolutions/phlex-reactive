# frozen_string_literal: true

# reactive_lazy(cache:) fixture (issue #277): a per-viewer menu the page ships
# as a shell with a STABLE fragment URL. The client GETs it on connect; the
# reply is `Cache-Control: private`, so a second page view reuses the browser's
# copy. It renders the viewer (from the session, never from the URL), is denied
# for the "banned" viewer (a registered authorization error → 403), opts out
# with render? false for the "hidden" scope, and busts its URL through
# reactive_cache_version (the class-level dial specs turn).
class CachedMenuComponent < ApplicationComponent
  include Phlex::Reactive::Streamable
  include Phlex::Reactive::Component

  class Denied < StandardError; end

  # Spec dials, read and written from the request thread AND the example's:
  # atomic, so overlapping renders can't lose a count.
  VERSION = Concurrent::AtomicReference.new
  RENDERS = Concurrent::AtomicFixnum.new

  class << self
    def version = VERSION.get

    def version=(value)
      VERSION.set(value)
    end

    def renders = RENDERS.value

    def renders=(value)
      RENDERS.value = value
    end
  end

  reactive_state :scope

  reactive_lazy cache: { max_age: 10.minutes }, tag: :ul

  def initialize(scope: "main")
    @scope = scope
  end

  def id = "cached-menu"

  def render? = @scope != "hidden"

  def reactive_cache_version = self.class.version

  def reactive_cache_viewer = Viewer.who

  def deferred_placeholder = %(<li data-testid="menu-skeleton">…</li>).html_safe

  def view_template
    raise Denied, "no menu for you" if Viewer.who == "banned"

    RENDERS.increment
    ul(id:, **reactive_attrs) do
      li(data: { testid: "menu-item" }) { "menu:#{@scope}:#{Viewer.who || "guest"}" }
    end
  end
end
