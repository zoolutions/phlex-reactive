# frozen_string_literal: true

# phlex-reactive config for the docs app. The defaults (renderer =
# ActionController::Base, base_controller = ActionController::Base) already make
# the record-backed demos work; this only wires the failure-surface example.
Rails.application.config.after_initialize do
  # The docs app's demo components (chat, counters, the team inbox) are showcases
  # with no authorization layer, so the default-ON verify_authorized guard (#168)
  # would raise on every unauthorized demo action. Disable it here — the same
  # posture as the gem's dummy app; a real app leaves it on and authorizes.
  Phlex::Reactive.verify_authorized = false

  # Register the failure-surface demo's authorization error so a DECLARED action
  # that denies returns a clean 403 (client kind=http) — mirroring how a real app
  # registers Pundit::NotAuthorizedError. The page still renders under the
  # render-time undeclared-action guard because `boom` IS declared.
  Phlex::Reactive.authorization_errors << FailureSurfaceComponent::Denied

  # The flagship Team inbox: a locked message refuses to archive. Registering the
  # error maps the denial to a clean 403 so the client reverts the optimistic hide.
  Phlex::Reactive.authorization_errors << TeamInboxComponent::Locked

  # The Presence demo (issue #358) refuses an unknown colour.
  Phlex::Reactive.authorization_errors << PresenceDemoComponent::Denied

  # Presence needs a member per SSE connection; the docs have no sign-in, so
  # every visitor is a guest. Only on a pgbus with per-connection presence —
  # the signature probe, never capable? (a query; boot may have no database).
  if Phlex::Reactive::Presence::Transport.wired? && Pgbus.configuration.respond_to?(:streams_presence_member=)
    Pgbus.configuration.streams_presence_member = ->(_context) { { id: 'guest', metadata: { name: 'Guest' } } }
  end

  # With error_flash set, the endpoint renders a turbo-stream flash the browser
  # SHOWS on a failed action, and the client marks the root data-reactive-error.
  Phlex::Reactive.error_flash = ->(kind) { "Something went wrong (#{kind})." }
end
