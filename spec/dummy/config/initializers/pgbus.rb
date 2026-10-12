# frozen_string_literal: true

# Issue #187: the dummy boots pgbus ONLY under TRANSPORT=pgbus, so the default
# suite stays Postgres-free and Action-Cable-backed. pgbus is `require: false`
# in the Gemfile (never a runtime dependency of the gem), so we require it here.
# Once required, pgbus's engine initializer patches Turbo::StreamsChannel to
# route broadcasts over Postgres SSE and swaps turbo_stream_from's cable source
# for <pgbus-stream-source> — the phlex-reactive broadcast path is unchanged.
#
# streams_test_mode is left OFF: this env exists to exercise REAL streaming
# (rack.hijack SSE), so the browser suite proves cross-tab delivery + actor-echo
# exclusion end to end. The unit/request layers keep using doubles / test mode.
# pgbus itself is required in config/application.rb (BEFORE Rails initializers,
# so its engine patch installs) — here we only configure it.
if ENV["TRANSPORT"] == "pgbus"
  Pgbus.configure do
    # Signing secret: Turbo.signed_stream_verifier_key (from secret_key_base) is
    # used first; set an explicit one so the dummy needs no credentials file.
    it.streams_signed_name_secret = "phlex-reactive-dummy-pgbus-test-secret"
    # streams_test_mode OFF: this env exists to exercise REAL streaming (the SSE
    # stub the default test mode returns would defeat the whole point). Broadcasts
    # deliver in the web process (one streamer per Puma worker / Falcon reactor) —
    # phlex-reactive's broadcast_*_to calls Pgbus.stream(...).broadcast(...) inline,
    # so no worker/supervisor is needed for a single-process Capybara server.
    it.streams_test_mode = false
    # Issue #358: presence takes each connection's identity from what
    # streams_authorize returns (pgbus >= 0.18, the engine mount's hook). The
    # dummy has no sign-in, so every connection is the same guest; an app
    # returns its user, and only when that user may read the stream.
    it.streams_authorize = ->(_env, _stream_name) { { id: "guest", metadata: { name: "Guest" } } }
  end
end
