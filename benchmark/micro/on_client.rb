# frozen_string_literal: true

# Micro-bench: on_client, which builds a client-op trigger's attributes on EVERY
# render. Issue #271 made each call build a binding record ({on, ops, flags})
# and write it space-free (gsub " " ->  ) so several bindings compose via
# mix. This isolates that per-call cost, plus a full render of a component that
# carries several on_client triggers.
#
#   ruby benchmark/micro/on_client.rb

require_relative "../support/boot"

component = ClientTabsComponent.new
plain = component.js.toggle("#menu")
spaced = component.js.hide(".panel").show("#panel-2").text("#status", "Second panel")

BenchSupport.header("on_client throughput")
BenchSupport.ips do
  it.report("on_client(:click, toggle)") { component.send(:on_client, :click, plain) }
  it.report("on_client(outside:, spaced chain)") { component.send(:on_client, :click, spaced, outside: true) }
end

BenchSupport.header("on_client allocations (per call)")
BenchSupport.allocations("on_client(:click, toggle)") { component.send(:on_client, :click, plain) }
BenchSupport.allocations("on_client(outside:, spaced chain)") do
  component.send(:on_client, :click, spaced, outside: true)
end

BenchSupport.header("ClientTabsComponent render (5 on_client triggers)")
BenchSupport.ips do
  it.report("render ClientTabsComponent") { ClientTabsComponent.new.call }
end
BenchSupport.allocations("render ClientTabsComponent") { ClientTabsComponent.new.call }
