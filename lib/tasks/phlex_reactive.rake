# frozen_string_literal: true

# Rails engines auto-load rake tasks under lib/tasks — no engine.rb change is
# needed for `bin/rails phlex_reactive:doctor` to appear in the host app.
namespace :phlex_reactive do
  desc "Validate the phlex-reactive install (route, Stimulus, verifier, components) — issue #106"
  task doctor: :environment do
    # Doctor.run eager-loads so the component registry is populated, prints the
    # ✓/✗/? report (with a fix per failure), and returns false if any check
    # FAILED (advisory `?` lines don't count) — abort so CI / a setup script can
    # gate on `bin/rails phlex_reactive:doctor`.
    abort unless Phlex::Reactive::Doctor.run
  end

  desc "List every declared reactive action (component | action | params | file:line | auth); " \
       "FORMAT=json for tooling, UNVERIFIED=1 for only the unverified rows"
  task actions: :environment do
    # eager_load! so every app component is in the Streamable registry the
    # Inspector reads. Plain text by default (no ANSI, like the doctor);
    # FORMAT=json emits a parseable array for tooling. Names/paths/schemas only.
    # UNVERIFIED=1 keeps only actions with neither a detected authorization call
    # nor a skip_verify_authorized — the review queue (issue #278).
    Rails.application.eager_load!
    format = ENV["FORMAT"].to_s.downcase == "json" ? :json : :text
    unverified_only = ENV["UNVERIFIED"].to_s == "1"
    puts Phlex::Reactive::Inspector::Report.actions(Phlex::Reactive::Inspector.components, format:, unverified_only:)
  end

  desc "Fuzzy-find a reactive component and print its actions with method-definition source — phlex_reactive:find[query]"
  task :find, [:query] => :environment do |_task, args|
    Rails.application.eager_load!
    query = args[:query].to_s
    puts Phlex::Reactive::Inspector::Report.find(Phlex::Reactive::Inspector.find(query), query)
  end

  desc "Run the read-only diagnostic MCP server over stdio (needs the optional `mcp` gem) — issue #168"
  task mcp: :environment do
    # Lazy-load the optional mcp gem + the tool tree (a helpful error if the gem
    # is missing), then drive the stdio transport. eager_load! so the tools see
    # every component. NOTHING may write to stdout but the JSON-RPC frames — the
    # runner documents this; keep initializers quiet on $stdout.
    Phlex::Reactive::MCP.load!
    Rails.application.eager_load!
    Phlex::Reactive::MCP::Runner.run
  end
end
