# frozen_string_literal: true

# Issue #187: prepare the Postgres test DB for the pgbus transport cell. Boots
# the dummy under TRANSPORT=pgbus (Postgres), loads the app schema, and installs
# pgbus's vendored PGMQ schema (idempotent — no CREATE EXTENSION, so it runs on a
# plain postgres:18). Run via `rake pgbus:prepare_test_db` (CI + spec:system_matrix).
require_relative "../dummy/config/environment"
require "pgbus/pgmq_schema"

ActiveRecord::Schema.verbose = false
load Rails.root.join("db/schema.rb")

conn = ActiveRecord::Base.connection
pgmq_present = conn
  .select_value("SELECT count(*) FROM information_schema.schemata WHERE schema_name = #{conn.quote("pgmq")}")
  .to_i
  .positive?
conn.execute(Pgbus::PgmqSchema.install_sql) unless pgmq_present

# Issue #358: the presence table (with per-connection seats), created from
# pgbus's OWN migration template so the dummy tracks whatever the installed
# pgbus ships. A pgbus without the template (before 0.17.3) leaves presence off,
# and the presence system spec skips on the capability probe.
presence_template = Gem.loaded_specs["pgbus"]&.full_gem_path
  &.then { File.join(it, "lib/generators/pgbus/templates/add_presence.rb.erb") }
if presence_template && File.exist?(presence_template) && !conn.table_exists?(:pgbus_presence_members)
  require "erb"
  migration_version = "[#{ActiveRecord::Migration.current_version}]"
  eval(ERB.new(File.read(presence_template)).result(binding)) # rubocop:disable Security/Eval -- pgbus's own template
  AddPgbusPresence.new.migrate(:up)
end

# This is a rake-invoked setup SCRIPT, not an example — the status line is for
# the CI log, not a spec expectation.
puts "pgbus test DB ready (app schema + PGMQ + presence)" # rubocop:disable RSpec/Output
