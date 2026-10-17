# frozen_string_literal: true

# Micro-bench: the broadcast render path — a NAMED hot path
# (AGENTS.md → Performance) that had no bench until issue #119.
#
# The transport (Turbo::StreamsChannel) is doubled out to a no-op: we are
# measuring the SERVER-SIDE cost a broadcast pays BEFORE the wire — build +
# render_component (the phlex-rails render_in) + the identity HMAC baked into
# the rendered root — not Action Cable / pgbus delivery.
#
# The point of the bench is the per-CALL multi-KEY cliff. Broadcasting one
# component to K different stream keys (a per-tenant loop — "the list page
# stream AND the dashboard stream") with a hand-written K-call loop is
# K× build + K× render + K× HMAC for BYTE-IDENTICAL HTML, because `*streamables`
# concatenates into ONE key. `broadcast_to(each: keys, ...)` (the issue #185
# spelling of the old _to_each) renders ONCE and fans the shared payload out
# over K cheap channel calls. This bench measures the gap at 1 key (parity)
# and over 10 keys (the win).
#
#   ruby benchmark/micro/broadcast.rb
#   rake bench:micro

require_relative "../support/boot"

# Double out the transport: a broadcast bench must not need a running Action
# Cable server (or pgbus's Postgres). We stub every broadcast_*_to entry point
# the benched methods reach to a no-op that returns nil, so what's left is
# purely the server-side build+render+HMAC cost this issue is about.
module Turbo
  class StreamsChannel
    class << self
      %i[broadcast_replace_to broadcast_update_to broadcast_append_to
         broadcast_prepend_to broadcast_remove_to broadcast_action_to].each do
        define_method(it) { |*, **| nil }
      end
    end
  end
end

KEYS = Array.new(10) { ["tenant:#{it}", :counters] }

BenchSupport.header("broadcast_to replace: 1 key vs a hand K-key loop vs each:")
BenchSupport.ips do
  # 1 key: the baseline single-key broadcast — one build + one render + one HMAC.
  it.report("replace (1 key)") do
    CounterComponent.broadcast_to(*KEYS.first, replace: nil)
  end

  # The naive K-key fan-out a developer writes today: K× everything for
  # byte-identical HTML. This is the cliff issue #119 removes.
  it.report("replace loop (10 keys)") do
    KEYS.each { CounterComponent.broadcast_to(*it, replace: nil) }
  end

  # The each: fan-out (issue #185 spelling of _to_each): render ONCE, fan out
  # over 10 cheap channel calls.
  it.report("replace each: (10 keys)") do
    CounterComponent.broadcast_to(each: KEYS, replace: nil)
  end
end

BenchSupport.header("allocations: K-key fan-out (loop vs each:), K=10")
# Warm the per-class view-context + token caches so we measure the steady state.
CounterComponent.broadcast_to(*KEYS.first, replace: nil)
BenchSupport.allocations("replace loop (10 keys)") do
  KEYS.each { CounterComponent.broadcast_to(*it, replace: nil) }
end
BenchSupport.allocations("replace each: (10 keys)") do
  CounterComponent.broadcast_to(each: KEYS, replace: nil)
end

# --- model_param_name: a measure-first candidate (issue #119) --------------
# It allocates a String (demodulize/underscore) + a Symbol per class-level
# call for a NON-reactive_record component. It's called once per build (per
# broadcast/render). Bench it HERE and memoize ONLY if the number is material —
# otherwise the honest answer is "measured, left alone."
BenchSupport.header("model_param_name (measure-first: memoize only if material)")
BenchSupport.ips do
  it.report("model_param_name") { CounterComponent.model_param_name }
end
BenchSupport.allocations("model_param_name") { CounterComponent.model_param_name }
