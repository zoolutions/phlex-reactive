# frozen_string_literal: true

require "English"
require "rspec/core/rake_task"

# Unit + request specs (the fast suite the release task runs). System specs need
# a browser and run in CI; invoke them explicitly with `rake spec:system`.
RSpec::Core::RakeTask.new(:spec) do |t|
  t.pattern = "spec/{phlex,requests}/**/*_spec.rb"
end

namespace :spec do
  desc "Run browser system specs (needs Playwright). CAPYBARA_SERVER=puma|falcon (default puma)"
  RSpec::Core::RakeTask.new(:system) do |t|
    t.pattern = "spec/system/**/*_spec.rb"
  end

  desc "Run the browser system specs under BOTH real servers (puma + falcon)"
  task :system_servers do
    # A reactive round trip must be transport-agnostic — prove it under both the
    # sync (Puma) and async (Falcon) server before a client-touching change ships.
    %w[puma falcon].each do |server|
      puts "\e[1;35m\n### system specs under CAPYBARA_SERVER=#{server} ###\e[0m"
      sh({ "CAPYBARA_SERVER" => server }, "bundle exec rspec spec/system")
    end
  end

  # The specs that exercise what only the OPT-IN split client does (issue
  # #275): a feature module imported on demand, the import window, replayed
  # and dormant triggers across it, and request counting.
  split_client_specs = %w[
    spec/system/persist_feature_spec.rb
    spec/system/defer_feature_spec.rb
    spec/system/persist_form_spec.rb
    spec/system/persist_editors_spec.rb
    spec/system/defer_spec.rb
    spec/system/lazy_mount_spec.rb
    spec/system/lazy_on_spec.rb
    spec/system/lazy_cache_spec.rb
    spec/system/early_triggers_spec.rb
    spec/system/dormant_root_spec.rb
    spec/system/dormant_cache_spec.rb
    spec/system/reactive_request_count_spec.rb
  ]

  desc "Run the split-client system specs (phlex/reactive/core + features on demand) under the current server"
  task :system_split do
    # The full suite runs on the DEFAULT client (one bundled file). This is the
    # focused set for the opt-in entry; CAPYBARA_SERVER picks the server.
    sh({ "REACTIVE_CLIENT" => "split" }, "bundle exec rspec #{split_client_specs.join(" ")}")
  end

  desc "Run the browser system specs across server × transport (puma/falcon × cable/pgbus)"
  task :system_matrix do
    # Issue #187: the full transport matrix, mirroring :system_servers one
    # dimension over. The pgbus cells need Postgres + the pgbus schema (rake
    # pgbus:prepare_test_db); they're SKIPPED with a clear note when Postgres
    # isn't reachable locally, so the cable cells still prove the round trip.
    servers = %w[puma falcon]
    transports = %w[cable pgbus]
    postgres = system("pg_isready", %i[out err] => File::NULL)
    warn "\e[1;33m\n### Postgres not reachable — skipping pgbus cells (cable only) ###\e[0m" unless postgres

    servers.each do |server|
      transports.each do |transport|
        pgbus = transport == "pgbus"
        next puts("\e[1;33m### SKIP #{server}/pgbus (no Postgres) ###\e[0m") if pgbus && !postgres

        sh({ "TRANSPORT" => "pgbus" }, "bundle exec rake pgbus:prepare_test_db") if pgbus
        puts "\e[1;35m\n### system specs — CAPYBARA_SERVER=#{server} TRANSPORT=#{transport} ###\e[0m"
        sh({ "CAPYBARA_SERVER" => server, "TRANSPORT" => transport }, "bundle exec rspec spec/system")
      end
    end
  end
end

namespace :pgbus do
  desc "Prepare the Postgres test DB for the pgbus transport cell (schema + PGMQ) — issue #187"
  task :prepare_test_db do
    # The setup lives in spec/support/prepare_pgbus_db.rb (boots the dummy under
    # TRANSPORT=pgbus, loads the app schema, installs pgbus's vendored PGMQ — no
    # CREATE EXTENSION, so a plain postgres:18 works). Used by CI and :system_matrix.
    sh({ "TRANSPORT" => "pgbus", "RAILS_ENV" => "test" },
      "bundle exec ruby spec/support/prepare_pgbus_db.rb")
  end
end

require "rubocop/rake_task"
RuboCop::RakeTask.new

# --- Performance benchmarks -------------------------------------------------
# Micro-benches isolate the hot methods (render, reactive_token, param
# coercion); the request bench drives the dummy app through derailed_benchmarks
# for end-to-end latency + memory. See docs/performance.md.
namespace :bench do
  micro_dir = "benchmark/micro"

  desc "Run the micro-benchmarks (render, token, coerce_params)"
  task :micro do
    files = Dir["#{micro_dir}/*.rb"]
    abort "No micro-benchmarks found in #{micro_dir}" if files.empty?

    # Capture a plain-text report (CI uploads it as an artifact) while still
    # streaming to the console. Strip ANSI colors from the saved copy.
    require "fileutils"
    FileUtils.mkdir_p("tmp/benchmarks")
    failed = []
    File.open("tmp/benchmarks/micro.txt", "w") do |out|
      files.each do |file|
        header = "\n### #{file} ###"
        puts "\e[1;35m#{header}\e[0m"
        out.puts header
        result = `ruby #{file} 2>&1`
        puts result
        out.puts result.gsub(/\e\[[0-9;]*m/, "")
        # A crashed bench must not pass silently — record the failure (and note it
        # in the saved report) so CI surfaces a broken bench instead of a green tick.
        unless $CHILD_STATUS.success?
          failed << file
          out.puts "!!! FAILED (exit #{$CHILD_STATUS.exitstatus})"
        end
      end
    end
    puts "\nSaved report to tmp/benchmarks/micro.txt"
    abort "\nBenchmark(s) failed: #{failed.join(", ")}" if failed.any?
  end

  desc "Run a single micro-benchmark: rake bench:one[render]"
  task :one, [:name] do |_t, args|
    name = args[:name] or abort "Usage: rake bench:one[render|token|coerce_params]"
    # Resolve against the actual bench files (no shell interpolation of arbitrary
    # input into an executable path) so a stray name can't escape the benchmark dir.
    available = Dir["#{micro_dir}/*.rb"].map { |f| File.basename(f, ".rb") }
    abort "No such benchmark: #{name}. Available: #{available.sort.join(", ")}" unless available.include?(name)
    ruby "#{micro_dir}/#{name}.rb"
  end

  desc "End-to-end request-cycle benchmark (derailed; needs a booted dummy app)"
  task :request do
    require "fileutils"
    FileUtils.mkdir_p("tmp/benchmarks")
    sh({ "RAILS_ENV" => "test" }, "ruby benchmark/request/derailed.rb")
  end

  desc "Run the client dispatch micro-benchmarks (extractToken, collectFields, recompute) via bun"
  task :client do
    # The client hot path (reactive_controller.js) is benched off-browser with
    # mitata + happy-dom, driven through the controller's PUBLIC surface only —
    # so NOTHING under app/javascript/ is touched (no __bench exports). See
    # benchmark/client/ and docs/…/performance.rb for the honest framing (the
    # happy-dom numbers are engine-relative; the extractToken regex numbers are
    # engine-faithful under bun/JSC).
    require "fileutils"
    FileUtils.mkdir_p("tmp/benchmarks")
    header = "\n### benchmark/client/index.bench.js ###"
    puts "\e[1;35m#{header}\e[0m"
    result = `bun run benchmark/client/index.bench.js 2>&1`
    puts result
    File.open("tmp/benchmarks/client.txt", "w") do |out|
      out.puts header
      out.puts result.gsub(/\e\[[0-9;]*m/, "")
      # A crashed bench must not pass silently — index.bench.js runs mitata with
      # `throw: true`, so a throwing bench exits non-zero. Record the failure in
      # the saved report and abort, matching the bench:micro contract.
      out.puts "!!! FAILED (exit #{$CHILD_STATUS.exitstatus})" unless $CHILD_STATUS.success?
    end
    puts "\nSaved report to tmp/benchmarks/client.txt"
    abort "\nClient benchmark failed (exit #{$CHILD_STATUS.exitstatus})" unless $CHILD_STATUS.success?
  end
end

desc "Run the micro-benchmark suite (alias for bench:micro)"
task bench: "bench:micro"

# --- Client build -----------------------------------------------------------
# The browser ships a MINIFIED twin of each authored client module (the source
# stays comment-dense — it's the documentation and what the JS suite imports).
# Output is deterministic, so the .min.js/.min.js.map are committed and shipped
# in the gem; consumers need no bun. See scripts/build_client.js.
namespace :build do
  # A pathspec, not a shell glob: its `*` crosses directories, so this also
  # guards the feature modules under features/ (issue #275). Do not "fix" it
  # to `**/` — that stops matching the top-level files.
  min_glob = "app/javascript/phlex/reactive/*.min.js*"

  desc "Minify the client runtime (reactive_controller/confirm/compute) via bun"
  task :js do
    sh "bun run scripts/build_client.js"
  end

  desc "Verify the committed minified client matches a fresh build (CI drift guard)"
  task js_check: :js do
    # A deterministic build means the rebuild leaves the tracked artifacts
    # byte-identical to what's checked in. `git diff` compares the working tree
    # against the index/HEAD, so a fresh checkout that rebuilds cleanly passes;
    # a source edit without a rebuild-and-commit shows a diff and fails CI.
    # The pathspec is QUOTED so git expands it against the index — not the shell
    # against the working tree: an unquoted glob only sees files still on disk, so
    # deleting a module (and its committed .min.js/.map) would slip past the guard.
    sh "git diff --exit-code -- '#{min_glob}'" do |ok, _res|
      unless ok
        warn "\e[31mMinified client is stale — run `rake build:js` and commit the result.\e[0m"
        abort "Committed .min.js/.min.js.map do not match a fresh build."
      end
    end
  end
end

desc "Build gem and verify contents"
task :build do
  sh("gem build phlex-reactive.gemspec --strict")
  gem_file = Dir["phlex-reactive-*.gem"].first
  abort "Gem file not found after build" unless gem_file

  sh("gem unpack #{gem_file} --target /tmp/gem-verify")
  puts "\n=== Gem contents ==="
  sh("find /tmp/gem-verify -type f | sort")
  sh("rm -rf /tmp/gem-verify #{gem_file}")
end

# `rake release[X.Y.Z]` lives in rakelib/release.rake (shared across the
# zoolutions gems); `bin/release` is its interactive front door.

namespace :dummy do
  desc "Run the dummy app for local QA (PORT=3010)"
  task :server do
    port = ENV.fetch("PORT", "3010")
    ENV["RAILS_ENV"] = "development"
    sh("bundle exec puma spec/dummy/config.ru -p #{port}")
  end
end

task default: %i[spec rubocop]
