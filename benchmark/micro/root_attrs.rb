# frozen_string_literal: true

# Micro-bench: reactive_attrs / reactive_root, the root-attribute assembly that
# runs on EVERY render. Issue #274 added the dormant decision to it — one
# registry read per call for an awake root, plus one fiber-local read for a
# dormant one — so this pins what that costs next to the token signing that
# dominates the call.
#
#   ruby benchmark/micro/root_attrs.rb

require_relative "../support/boot"

awake = CounterComponent.new(count: 42)
dormant = DormantPanelComponent.new(clicks: 42)

BenchSupport.header("root attrs throughput")
BenchSupport.ips do
  it.report("reactive_attrs (awake)") { awake.send(:reactive_attrs) }
  it.report("reactive_root (awake)") { awake.send(:reactive_root) }
  it.report("reactive_root (dormant)") { dormant.send(:reactive_root) }
end

BenchSupport.header("root attrs allocations (per call)")
awake.send(:reactive_root) # warm the class-level caches
dormant.send(:reactive_root)
BenchSupport.allocations("reactive_attrs (awake)") { awake.send(:reactive_attrs) }
BenchSupport.allocations("reactive_root (awake)") { awake.send(:reactive_root) }
BenchSupport.allocations("reactive_root (dormant)") { dormant.send(:reactive_root) }
