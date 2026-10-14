# frozen_string_literal: true

# Micro-bench: Phlex::Reactive.verify and .sign — the two MessageVerifier HMAC
# paths that run on EVERY reactive interaction (issue #120).
#
#   * verify runs pre-EVERYTHING on every request (ActionsController#verified_payload
#     is the first line — before default-deny, before coercion), so a garbage-token
#     flood pays it too.
#   * sign runs ONCE per rendered component (reactive_token) — N times for an
#     N-row reactive collection, so the ×100 number below is the collection cost.
#
# token.rb covers the sign-side ASSEMBLY (building the payload hash + ivar reads);
# THIS file isolates the HMAC itself and answers a question the repo's own perf
# rule forbids leaving unmeasured: is verify cheap, and does the digest/serializer
# choice move it? See docs/performance.rb "Verify & sign numbers".
#
#   ruby benchmark/micro/verify.rb
#   rake bench:one[verify]

require_relative "../support/boot"
require "active_support/message_verifier"

PURPOSE = Phlex::Reactive::IDENTITY_PURPOSE

# --- Fixtures ---------------------------------------------------------------
# Real tokens minted the way a render does — via the components, so the payload
# shapes ({c, s} state-backed, {c, gid} record-backed) match production exactly.
state    = CounterComponent.new(count: 42)                 # {c, s}
todo     = Todo.create!(title: "t", done: false)
record   = TodoItemComponent.new(todo:)                    # {c, gid}
state_token  = state.send(:reactive_token)
record_token = record.send(:reactive_token)

# A TAMPERED token: corrupt the signature deterministically. A signed token is
# `payload--signature`; flip the last char of the segment AFTER the final `--`
# (the HMAC), leaving the format intact so verify runs the FULL constant-time
# HMAC compare before rejecting. (Corrupting via sub("a", "b") on the whole
# string is fragile — it might hit the payload, or the char might be absent.)
def tamper(token)
  head, _, sig = token.rpartition("--")
  flipped = sig[-1] == "0" ? "1" : "0"
  "#{head}--#{sig[0...-1]}#{flipped}"
end
tampered_token = tamper(state_token)

# A GARBAGE string: not remotely a signed token. verify bails at FORMAT parsing
# (no valid base64 payload / no `--` split) — it never reaches the HMAC compare.
# This is why tampered ≠ garbage: tampered pays the full HMAC (constant-time
# compare of the whole digest); garbage pays only the early format bail. Under a
# bad-token flood the attacker sends garbage, so the cheaper number is the flood
# cost — but a near-miss forgery attempt pays the tampered (full-HMAC) cost.
garbage_token = "x" * 64

# --- verify throughput ------------------------------------------------------
BenchSupport.header("verify throughput (per token)")
BenchSupport.ips do
  it.report("valid (state {c,s})") { Phlex::Reactive.verify(state_token) }
  it.report("valid (record {c,gid})") { Phlex::Reactive.verify(record_token) }
  it.report("tampered (full HMAC)") { Phlex::Reactive.verify(tampered_token) }
  it.report("garbage (format bail)") { Phlex::Reactive.verify(garbage_token) }
end

BenchSupport.header("verify allocations (per call)")
Phlex::Reactive.verify(state_token) # warm
BenchSupport.allocations("valid (state)")    { Phlex::Reactive.verify(state_token) }
BenchSupport.allocations("valid (record)")   { Phlex::Reactive.verify(record_token) }
BenchSupport.allocations("tampered")         { Phlex::Reactive.verify(tampered_token) }
BenchSupport.allocations("garbage")          { Phlex::Reactive.verify(garbage_token) }

# --- sign throughput: 1 and 100 (the collection-scale cost) -----------------
# Sign the exact payloads reactive_token builds. ×100 is the per-CALL cost of
# rendering a 100-row reactive collection (one sign per row).
state_payload  = { "c" => "CounterComponent", "s" => { "count" => 42 } }
record_payload = { "c" => "TodoItemComponent", "gid" => todo.to_gid.to_s }

BenchSupport.header("sign throughput (×1 and ×100)")
BenchSupport.ips do
  it.report("state ×1")   { Phlex::Reactive.sign(state_payload) }
  it.report("record ×1")  { Phlex::Reactive.sign(record_payload) }
  it.report("state ×100") { 100.times { Phlex::Reactive.sign(state_payload) } }
  it.report("record ×100") { 100.times { Phlex::Reactive.sign(record_payload) } }
end

BenchSupport.header("sign allocations (per call)")
Phlex::Reactive.sign(state_payload) # warm
BenchSupport.allocations("state ×1")   { Phlex::Reactive.sign(state_payload) }
BenchSupport.allocations("record ×1")  { Phlex::Reactive.sign(record_payload) }
BenchSupport.allocations("state ×100") { 100.times { Phlex::Reactive.sign(state_payload) } }

# --- digest / serializer comparison -----------------------------------------
# The default verifier takes whatever Rails.application.message_verifier hands
# back: SHA1 digest, the JSON-with-Marshal-fallback serializer. Does pinning
# SHA256 or a strict JSON serializer move the number? Build explicit verifiers
# on the SAME secret + purpose so only the one variable changes. Each round-trips
# a token it minted itself (a cross-verifier token wouldn't verify).
secret = Rails.application.secret_key_base

variants = {
  "app default (SHA1, json+marshal)" => Phlex::Reactive.verifier,
  "SHA1  + JSON serializer" => ActiveSupport::MessageVerifier.new(secret, digest: "SHA1", serializer: JSON),
  "SHA256 + json+marshal (default)" => ActiveSupport::MessageVerifier.new(secret, digest: "SHA256"),
  "SHA256 + JSON serializer" => ActiveSupport::MessageVerifier.new(secret, digest: "SHA256", serializer: JSON)
}
# Mint one token per variant (same {c,s} payload) so the verify measures the
# variant's own round-trip, not a decode failure.
variant_tokens = variants.transform_values { it.generate(state_payload, purpose: PURPOSE) }

# The ips block is named `|bench|` (not the implicit `it`) ON PURPOSE: it wraps a
# `variants.each do |label, verifier|` whose ordinary params make a bare `it` a
# Ruby SyntaxError ("`it` is not allowed when an ordinary parameter is defined").
# The inner report blocks reference the captured `verifier`/`token`, so `it` there
# would be the report block's own (nil) param, not the verifier. (RuboCop 1.92's
# Style/ItBlockParameter leaves these nested blocks alone; no disable needed.)
BenchSupport.header("verify throughput by digest/serializer (valid state token)")
BenchSupport.ips do |bench|
  variants.each do |label, verifier|
    token = variant_tokens[label]
    bench.report(label) { verifier.verified(token, purpose: PURPOSE) }
  end
end

BenchSupport.header("sign throughput by digest/serializer (state payload)")
BenchSupport.ips do |bench|
  variants.each do |label, verifier|
    bench.report(label) { verifier.generate(state_payload, purpose: PURPOSE) }
  end
end
