# frozen_string_literal: true

# Render reactive components through the dummy's controller so dom_id and other
# view helpers work during re-renders and broadcasts.
Rails.application.config.after_initialize do
  Phlex::Reactive.renderer = DemosController

  # The dummy deliberately has no authorization layer — most of its components
  # are demos with no user/policy. verify_authorized (issue #168) is default-ON,
  # so disable it globally here; the dedicated verify_authorized feature specs
  # re-enable it around their examples and drive purpose-built fixtures
  # (AuthorizedTodoComponent, PublicCounterComponent).
  Phlex::Reactive.verify_authorized = false

  # Register the optimistic demo's authorization error so a DECLARED, slow-failing
  # action returns a clean 403 (issue #98 system spec) — mirroring how a real app
  # registers Pundit::NotAuthorizedError. Lets the failing-revert spec observe the
  # applied hint before the (deliberately delayed) failure reverts it, instead of
  # racing a fast default-deny 403.
  Phlex::Reactive.authorization_errors << OptimisticRowComponent::Denied
  Phlex::Reactive.authorization_errors << HintedPanelComponent::Denied

  # The `boom` fixtures (CounterComponent, FailureSurfaceComponent) deny inside a
  # DECLARED action so their pages still render under the render-time
  # undeclared-action guard (issue #105) while the endpoint still returns 403 —
  # the kind=http failure the lifecycle-events and failure-surface system specs
  # observe. Registering the errors maps them to that 403.
  Phlex::Reactive.authorization_errors << CounterComponent::Denied
  Phlex::Reactive.authorization_errors << FailureSurfaceComponent::Denied

  # verify_authorized fixture (issue #168): AuthorizedTodoComponent#rename_denied
  # raises this so the request spec proves a genuine denial still 403s through
  # authorization_errors — NOT the verify guard's 500.
  Phlex::Reactive.authorization_errors << AuthorizedTodoComponent::Denied
  # Defer :unauthorized contract fixture (issue #186): DeferAuthComponent raises on
  # render, so a deferred render maps to 403 + the defer instrument's :unauthorized.
  Phlex::Reactive.authorization_errors << DeferAuthComponent::Denied
  # reactive_lazy(on:) fixture (issue #276): __materialize shares the defer
  # endpoint's authorization step, so a render-time denial maps to 403.
  Phlex::Reactive.authorization_errors << LazyPanelComponent::Denied
  # reactive_lazy(cache:) fixture (issue #277): the fragment endpoint shares
  # that authorization step — a denied render is a 403, and never cacheable.
  Phlex::Reactive.authorization_errors << CachedMenuComponent::Denied
end
