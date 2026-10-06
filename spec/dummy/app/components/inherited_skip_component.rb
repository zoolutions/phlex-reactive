# frozen_string_literal: true

# Issue #302 fixture: a SUBCLASS of a reactive component. It never includes
# Phlex::Reactive::Component itself — it inherits the mixin, the bare
# skip_verify_authorized and the :increment action from PublicCounterComponent,
# and declares one action of its own. The actions inventory (rake tasks, MCP
# tools, doctor) must list it like any other resolvable component.
class InheritedSkipComponent < PublicCounterComponent
  action :reset

  def id = "inherited-skip"

  def reset = @count = 0
end
