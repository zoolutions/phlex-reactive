# frozen_string_literal: true

# Issue #358: the presence demo page. The roster mints its own
# <pgbus-stream-source>, so the page loads pgbus's client element itself
# (nothing else on it renders a pgbus helper that would).
class PresencePageComponent < Phlex::HTML
  def initialize(todo:)
    @todo = todo
  end

  def view_template
    script(type: "module") { raw safe(%(import "pgbus/stream_source_element")) }
    render TodoViewersComponent.new(todo: @todo)
  end
end
