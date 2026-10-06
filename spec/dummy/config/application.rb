# frozen_string_literal: true

require_relative "boot"

require "rails"
require "active_record/railtie"
require "active_job/railtie"
require "active_storage/engine"
require "action_controller/railtie"
require "action_view/railtie"
require "action_cable/engine"
require "turbo-rails"
require "phlex-rails"

Bundler.require(*Rails.groups)
require "phlex/reactive"
# Ensure the engine loads even if phlex/reactive was required before Rails
# (e.g. unit specs using spec_helper running before system specs).
require "phlex/reactive/engine"

# Issue #187: under TRANSPORT=pgbus, require pgbus HERE (it's require: false in
# the Gemfile) — BEFORE Rails runs its initializers — so pgbus's engine
# initializer ("pgbus.streams.turbo_broadcastable", after: load_config_initializers)
# actually joins the run list and patches Turbo::StreamsChannel + turbo_stream_from
# for the Postgres-SSE transport. Requiring it later (in config/initializers/)
# registers the engine too late and the patch silently never installs.
require "pgbus" if ENV["TRANSPORT"] == "pgbus"

module Dummy
  class Application < Rails::Application
    config.load_defaults Rails::VERSION::STRING.to_f
    config.eager_load = false
    config.hosts.clear
    config.active_job.queue_adapter = :test

    # Falcon serves each request as a fiber on one thread. Rails keys its
    # per-request state — and the lock on the connection transactional tests
    # PIN for the test and the server to share — on this setting: under the
    # default :thread, two request fibers look like one owner, both enter the
    # pinned connection's critical section, and the suite wedges on the first
    # page that makes two action requests overlap (ThreadError in
    # ConnectionPool#checkout; spec/system/falcon_fiber_isolation_spec.rb).
    # Fiber-per-request servers need :fiber, as Rails documents; the Puma cells
    # keep the stock :thread so both configurations stay proven.
    config.active_support.isolation_level = :fiber if ENV["CAPYBARA_SERVER"] == "falcon"

    # ActiveStorage: a local disk service rooted in tmp/ so the upload-action
    # fixture (issue #34 — file/multipart params) can persist an attachment.
    config.active_storage.service = :test_disk
    config.active_storage.service_configurations = {
      "test_disk" => { "service" => "Disk", "root" => root.join("tmp/storage").to_s }
    }

    # The dummy app's components/views live under app/.
    config.autoload_paths << root.join("app/components").to_s
  end
end
