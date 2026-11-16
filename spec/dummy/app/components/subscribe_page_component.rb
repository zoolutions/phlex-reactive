# frozen_string_literal: true

# Issue #474: the subscribe demo page. The component mints its own
# <pgbus-stream-source>, so the page loads pgbus's client element itself
# (nothing else on it renders a pgbus helper that would).
class SubscribePageComponent < Phlex::HTML
  def initialize(todo:)
    @todo = todo
  end

  def view_template
    script(type: "module") { raw safe(%(import "pgbus/stream_source_element")) }
    render TodoStatusComponent.new(todo: @todo)
  end
end
