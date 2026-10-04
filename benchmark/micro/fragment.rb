# frozen_string_literal: true

# Micro-bench: the cacheable-fragment path (issue #277). A `reactive_lazy
# cache:` shell signs its fragment id ONCE per page render (where a plain lazy
# shell signs a defer token), plus one SHA-256 per declared version / viewer;
# the endpoint verifies the id once per ORIGIN hit — a browser cache hit never
# reaches the server. Neither is on the per-render hot path (reactive_token
# is), so they are benched next to the plain lazy shell to keep the comparison
# honest: the cached shell must not cost meaningfully more than the shell it
# replaces.
#
#   ruby benchmark/micro/fragment.rb

require_relative "../support/boot"

panel = CachedPanelComponent.new(scope: "mine")
payload = panel.send(:reactive_identity_payload)
id = Phlex::Reactive.sign_fragment(payload)

BenchSupport.header("fragment id throughput")
BenchSupport.ips do
  it.report("sign_fragment") { Phlex::Reactive.sign_fragment(payload) }
  it.report("verify_fragment") { Phlex::Reactive.verify_fragment(id) }
  it.report("sign_defer (the plain shell's token)") { Phlex::Reactive.sign_defer(payload, unbound: true) }
end

BenchSupport.header("fragment URL (id + version + viewer digests)")
viewer = Phlex::Reactive::Fragment.viewer_param(42)
BenchSupport.ips do
  it.report("src (id only)") { Phlex::Reactive::Fragment.src(payload) }
  it.report("src (version + viewer)") do
    Phlex::Reactive::Fragment.src(payload, version: "2026-10-04", viewer: Phlex::Reactive::Fragment.viewer_param(42))
  end
end

BenchSupport.header("shell render: cached vs plain lazy")
BenchSupport.ips do
  it.report("plain lazy shell (defer token)") { LazyStatsComponent.new(scope: "week").call }
  it.report("cached shell (fragment URL + viewer)") { CachedMenuComponent.new(scope: "main").call }
  it.report("on: shell (identity token)") { LazyPanelComponent.new(scope: "mine").call }
  it.report("on: + cache: shell") { CachedPanelComponent.new(scope: "mine").call }
end

BenchSupport.header("allocations (per call)")
Phlex::Reactive.sign_fragment(payload) # warm
BenchSupport.allocations("sign_fragment") { Phlex::Reactive.sign_fragment(payload) }
BenchSupport.allocations("verify_fragment") { Phlex::Reactive.verify_fragment(id) }
BenchSupport.allocations("src (version + viewer)") do
  Phlex::Reactive::Fragment.src(payload, version: "2026-10-04", viewer:)
end
BenchSupport.allocations("plain lazy shell") { LazyStatsComponent.new(scope: "week").call }
BenchSupport.allocations("cached shell") { CachedMenuComponent.new(scope: "main").call }
BenchSupport.allocations("on: shell") { LazyPanelComponent.new(scope: "mine").call }
BenchSupport.allocations("on: + cache: shell") { CachedPanelComponent.new(scope: "mine").call }
