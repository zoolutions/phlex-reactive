# frozen_string_literal: true

# The deliberately-expensive rollup for the defer suite (issue #165) — the
# SessionTotals stand-in from the issue's reps-logger story. `render_delay_ms`
# is a class-level dial the request/system/latency specs turn to simulate a
# cross-aggregate rollup's cost; the default 0 keeps every other spec fast.
#
# It is a full reactive component (controller + fresh action token on the
# root) so the suite can prove a deferred render ARRIVES INTERACTIVE, and it
# defines deferred_placeholder so `placeholder: true` has a component-authored
# skeleton to pick up.
class SlowTotalsComponent < ApplicationComponent
  include Phlex::Reactive::Streamable
  include Phlex::Reactive::Component

  reactive_state :value

  # Test-fixture dials the defer specs set per example (issue #165), never
  # from two threads at once.
  # rubocop:disable-next ThreadSafety/ClassAndModuleAttributes
  class << self
    # Milliseconds of simulated render cost; specs dial it, suite default 0.
    attr_accessor :render_delay_ms
    # When true, render? is false — the defer endpoint's 204 no-op path.
    attr_accessor :suppressed
  end
  self.render_delay_ms = 0
  self.suppressed = false

  def initialize(value: 0)
    @value = value
  end

  def id = "slow-totals"

  def render? = !self.class.suppressed

  def deferred_placeholder = %(<span class="shimmer" data-testid="totals-shimmer">…</span>).html_safe

  def view_template
    delay = self.class.render_delay_ms
    sleep(delay / 1000.0) if delay.positive?
    div(id:, **reactive_attrs) do
      span(data: { testid: "totals-value" }) { @value.to_s }
    end
  end
end
