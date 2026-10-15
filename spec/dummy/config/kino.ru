# frozen_string_literal: true

# The report-only kino-smoke job (.github/workflows/main.yml,
# zoolutions/phlex-reactive#364): the dummy app served by kino in Ractor mode
# through ractor-rails-shim. It cannot pass until Rails and Phlex run in a
# non-main Ractor; the job's summary records how far it gets.
require "ractor_rails_shim"
RactorRailsShim.install

require_relative "environment"
RactorRailsShim.prepare_for_ractors!

run RactorRailsShim.make_app_shareable!(Rails.application)
