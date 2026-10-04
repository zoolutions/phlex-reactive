# frozen_string_literal: true

# A `cache:` fixture whose edge cases the fragment specs dial (issue #277):
#   * `viewer` — what reactive_cache_viewer returns. A blank value (nil, "",
#     false, whitespace, an Array with a blank part) names NO viewer, so the
#     component must fall back to the default mode for that render.
#   * the `markup` state — a render that embeds a CSRF token in one of the
#     spellings a template can produce (none of them may be cached), or
#     "nested": a plain reactive_lazy child.
class CachedProbeComponent < ApplicationComponent
  include Phlex::Reactive::Streamable
  include Phlex::Reactive::Component

  VIEWER = Concurrent::AtomicReference.new

  class << self
    def viewer = VIEWER.get

    def viewer=(value)
      VIEWER.set(value)
    end
  end

  MARKUP = {
    "single" => "<input type='hidden' name='authenticity_token' value='t0ken'>",
    "unquoted" => "<input type=hidden name=authenticity_token value=t0ken>",
    "spaced" => %(<input type="hidden" name = "authenticity_token" value="t0ken">),
    "upper" => %(<INPUT TYPE="hidden" NAME="authenticity_token" VALUE="t0ken">),
    "meta" => %(<meta name="csrf-token" content="t0ken">)
  }.freeze

  reactive_state :markup

  reactive_lazy cache: { max_age: 10.minutes }

  def initialize(markup: nil)
    @markup = markup
  end

  def id = "cached-probe"

  def reactive_cache_viewer = self.class.viewer

  def view_template
    div(id:, **reactive_attrs) do
      span { "who:#{Viewer.who || "guest"}" }
      # "nested": a plain reactive_lazy child inside the cached fragment.
      next render(LazyStatsComponent.new(scope: "week")) if @markup == "nested"

      raw(safe(MARKUP.fetch(@markup))) if @markup
    end
  end
end
