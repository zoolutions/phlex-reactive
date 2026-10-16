# frozen_string_literal: true

# Micro-bench: what the per-fiber view-context rebuild costs a Falcon request
# (zoolutions/phlex-reactive#364). The off-request view context and the Turbo
# stream builder are cached in Thread.current[], which is FIBER-local: under
# Puma one thread serves many requests and builds them once; under Falcon every
# request is a new fiber and builds them again. This measures that build, then
# a full action round trip twice, through the Rack stack:
#
#   * in one fiber, as Puma's threads serve requests (the caches stay warm);
#   * each request in a NEW fiber, as Falcon serves them (the caches rebuild).
#
# The difference between the two is an upper bound on what a shared pool of
# view contexts could save a Falcon request: it also includes creating and
# resuming the fiber, which a pool would not remove. A pool is worth its
# complexity only if that share of the round trip is large.
#
#   ruby benchmark/micro/view_context.rb

require_relative "../support/boot"
require "rack/mock"
require "json"

renderer = Phlex::Reactive.renderer

BenchSupport.header("building the off-request view context (#{renderer.name})")
BenchSupport.ips do
  it.report("request_bound_view_context") { Phlex::Reactive.request_bound_view_context(renderer) }
end
BenchSupport.allocations("request_bound_view_context") { Phlex::Reactive.request_bound_view_context(renderer) }

mock = Rack::MockRequest.new(Rails.application)
token = Phlex::Reactive.sign("c" => "CounterComponent", "s" => { "count" => 1 })
body = { token:, act: "increment", params: {} }.to_json
post = lambda do
  response = mock.post(Phlex::Reactive.action_path, :input => body, "CONTENT_TYPE" => "application/json",
    "HTTP_ACCEPT" => "text/vnd.turbo-stream.html")
  abort "[bench] the action returned HTTP #{response.status}, expected 200" unless response.status == 200
end
post.call

BenchSupport.header("an action round trip: warm caches (Puma) vs a new fiber per request (Falcon)")
# Longer than the other benches: a round trip is ~1 ms and GC-noisy.
BenchSupport.ips(time: 5, warmup: 2) do
  it.report("same fiber (caches warm)") { post.call }
  it.report("new fiber per request") { Fiber.new { post.call }.resume }
end
BenchSupport.allocations("same fiber (caches warm)") { post.call }
BenchSupport.allocations("new fiber per request") { Fiber.new { post.call }.resume }
