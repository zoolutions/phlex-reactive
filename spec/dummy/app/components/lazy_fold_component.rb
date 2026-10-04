# frozen_string_literal: true

# reactive_lazy(on: :visible) fixture (issue #276): rendered below the fold,
# it requests its real render only once the shell scrolls into view.
class LazyFoldComponent < ApplicationComponent
  include Phlex::Reactive::Streamable
  include Phlex::Reactive::Component

  reactive_state :label

  reactive_lazy on: :visible

  def initialize(label: "fold")
    @label = label
  end

  def id = "lazy-fold"

  def deferred_placeholder = %(<span data-testid="fold-skeleton">…</span>).html_safe

  def view_template
    div(id:, **reactive_attrs) do
      span(data: { testid: "fold-value" }) { "loaded:#{@label}" }
    end
  end
end
