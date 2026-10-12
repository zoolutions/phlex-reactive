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

  # Presence takes each SSE connection's identity from what streams_authorize
  # returns (pgbus >= 0.18). The docs have no sign-in, so the identity is the
  # visitor id ApplicationController keeps in the session; a request without
  # one is authorized with no identity (pgbus joins it to no roster). Every
  # demo stream here is public; a real app returns its user only when that user
  # may read the record behind stream_name (a signed name is not authorization).
  # Only on a wired pgbus — the signature probe, never capable? (a query; boot
  # may have no database).
  if Phlex::Reactive::Presence::Transport.wired?
    Pgbus.configuration.streams_authorize = lambda do |env, _stream_name|
      visitor = ActionDispatch::Request.new(env).session[:presence_visitor]
      visitor ? { id: visitor, metadata: { name: "Visitor #{visitor.upcase}" } } : true
    end
  end

  # With error_flash set, the endpoint renders a turbo-stream flash the browser
  # SHOWS on a failed action, and the client marks the root data-reactive-error.
  Phlex::Reactive.error_flash = ->(kind) { "Something went wrong (#{kind})." }
end
