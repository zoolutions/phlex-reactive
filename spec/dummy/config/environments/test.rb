# frozen_string_literal: true

Rails.application.configure do
  # As Rails' generated test.rb: with reloading on, the file watcher globs
  # app/ on every request (a third of a request's allocations).
  config.enable_reloading = false
  config.eager_load = false
  config.consider_all_requests_local = true
  config.action_dispatch.show_exceptions = :rescuable
  config.active_support.deprecation = :stderr
  config.action_controller.allow_forgery_protection = false

  # Secrets for session/CSRF and the identity verifier.
  config.secret_key_base = "test_secret_key_base_for_phlex_reactive"
end
