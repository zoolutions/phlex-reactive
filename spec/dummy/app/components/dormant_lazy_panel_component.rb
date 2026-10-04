# frozen_string_literal: true

# Issue #274 + #276: "load this panel the first time it opens, and fetch no
# JavaScript until then" — a reactive_lazy(on:) event shell that is also
# dormant. The shell's once-bound `__materialize` trigger is an ordinary
# descriptor, so `panel:opened` wakes the root AND materializes it, once.
class DormantLazyPanelComponent < LazyPanelComponent
  reactive_dormant

  def id = "dormant-lazy-panel"
end
