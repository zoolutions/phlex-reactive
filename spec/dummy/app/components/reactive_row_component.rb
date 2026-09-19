# frozen_string_literal: true

# A single row that is ITSELF reactive (issue #44). Unlike NotificationRowComponent
# (which carries no token of its own), this row declares reactive_record and renders
# `reactive_attrs` on its root — so its `<li>` carries its OWN
# data-reactive-token-value. When it is appended/prepended INTO a container whose
# #id equals the append target, the row's embedded token sat in the SAME stream
# string as `target="<container>"`, fooling carries_token_for? into skipping the
# container's token refresh — the add-once-only bug this fixture reproduces.
class ReactiveRowComponent < ApplicationComponent
  include Phlex::Reactive::Streamable
  include Phlex::Reactive::Component

  reactive_record :todo
  action :toggle

  def initialize(todo:)
    @todo = todo
  end

  def id = dom_id(@todo)

  def toggle
    @todo.update!(done: !@todo.done)
    reply.replace
  end

  def view_template
    # mix() deep-merges so reactive_attrs' data: (controller + token) survives
    # ALONGSIDE data-testid — a bare `data:` next to `**reactive_attrs` would
    # clobber one of them (AGENTS.md "Never Do #8").
    li(id:, class: "reactive-row", **mix(reactive_attrs, data: { testid: "reactive-row" })) do
      span(class: "body") { @todo.title }
      button(**mix(on(:toggle), data: { testid: "toggle" })) { "✓" }
    end
  end
end
