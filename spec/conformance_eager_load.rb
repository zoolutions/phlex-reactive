# frozen_string_literal: true

# conformance-kit's audit.require (.conformance.yml): boots the dummy app, which
# finalizes the configuration as an app's boot does, then loads every file of
# the gem so `conformance-audit --strict` audits all of Phlex::Reactive.
ENV["RAILS_ENV"] ||= "test"
require_relative "dummy/config/environment"

# The engine's app/ (the controllers), then lib/ through the gem's own loader.
Phlex::Reactive::Engine.eager_load!
Zeitwerk::Loader.eager_load_namespace(Phlex::Reactive)

# Left out of eager loading on purpose (they subclass ActiveJob::Base, which
# is optional); the dummy has ActiveJob, so load them here.
%i[DeferredRenderJob PresenceRenderJob].each { Phlex::Reactive.const_get(it) }

# The optional trees the loader ignores, each needing its own gem: the MCP
# tools (mcp) and the browser test helpers (capybara), both in the bundle.
Phlex::Reactive::MCP.load!
require "phlex/reactive/test_helpers"
require "phlex/reactive/test_helpers/system"
