# frozen_string_literal: true

# Only conformance-kit's report-only ractorize job (.conformance.yml ractorize:)
# boots the dummy in production: Rails main's `Rails.application.ractorize!`
# serves requests from non-main Ractors only from production settings that can
# be made shareable (conformance-kit's README, "What the app needs"; Rails'
# railties/test/application/ractors_test.rb). The job sets
# SECRET_KEY_BASE_DUMMY, so no secret lives here.
Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = true
  config.consider_all_requests_local = false

  config.logger = ActiveSupport::Ractors::Logger.new
  config.cache_store = :null_store
  config.public_file_server.enabled = false
  config.action_cable.mount_path = nil
  config.active_job.queue_adapter = :inline
end
