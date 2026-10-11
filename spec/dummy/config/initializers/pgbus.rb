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
    # Issue #358: a closed tab is noticed when the next heartbeat write to it
    # fails (pgbus has no read side on a hijacked SSE socket), so its presence
    # leave lands one heartbeat later — 15 s by default. A short beat lets the
    # browser suite see a leave in seconds.
    it.streams_heartbeat_interval = 2
    # Issue #358: every SSE connection is the same guest, so the presence
    # roster has someone to show (the dummy has no sign-in).
    if it.respond_to?(:streams_presence_member=)
      it.streams_presence_member = ->(_context) { { id: "guest", metadata: { name: "Guest" } } }
    end
  end
end
