# frozen_string_literal: true

require "capybara-playwright-driver"

HEADLESS = %w[1 true].include?(ENV.fetch("HEADLESS", "true"))

# Issue #320: bound every Playwright call explicitly, below the per-example
# watchdog (support/example_timeout.rb). In capybara-playwright-driver
# `timeout:` sets only the page's NAVIGATION timeout (visit/refresh/back) and
# `default_timeout:` every other call — both are Playwright's 30 s default
# today; spelled out so a driver/client upgrade can't silently unbound `visit`.
PLAYWRIGHT_TIMEOUT = Float(ENV.fetch("PLAYWRIGHT_TIMEOUT", 30))

Capybara.register_driver(:playwright) do
  Capybara::Playwright::Driver.new(
    it,
    playwright_cli_executable_path: "./node_modules/.bin/playwright",
    browser_type: :chromium,
    headless: HEADLESS,
    timeout: PLAYWRIGHT_TIMEOUT,
    default_timeout: PLAYWRIGHT_TIMEOUT
  )
end
