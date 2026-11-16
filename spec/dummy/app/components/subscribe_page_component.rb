# frozen_string_literal: true

# Issue #474: the subscribe demo page. The component mints its own
# <pgbus-stream-source>, so the page loads pgbus's client element itself
# (nothing else on it renders a pgbus helper that would). A finished todo's
# page also renders a source of its own at the end of <body>: a page refresh
# by morph then adds a server-rendered source beside the minted one.
class SubscribePageComponent < Phlex::HTML
  def initialize(todo:)
    @todo = todo
  end

  def view_template
    script(type: "module") { raw safe(%(import "pgbus/stream_source_element")) }
    render TodoStatusComponent.new(todo: @todo)
    return unless @todo.done?

    src = ERB::Util.html_escape(Phlex::Reactive::Defer.stream_src("subscribe-demo-extra"))
    raw safe(%(<pgbus-stream-source data-testid="extra-source" hidden src="#{src}"></pgbus-stream-source>))
  end
end
