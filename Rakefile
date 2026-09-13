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

desc "Release a new version (rake release[1.2.3] or rake release[pre] or rake release[1.2.3,force])"
task :release, %i[version force] do |_t, args|
  require_relative "lib/phlex/reactive/version"

  def info(msg) = puts "\e[34m→\e[0m #{msg}"
  def success(msg) = puts "\e[32m✓\e[0m #{msg}"
  def skip(msg) = puts "\e[33m⊘\e[0m #{msg} \e[33m(skipped)\e[0m"
  def header(msg) = puts "\n\e[1;36m#{msg}\e[0m\n#{"─" * msg.length}"

  new_version = args[:version]
  abort "\e[31mUsage: rake release[X.Y.Z] or rake release[X.Y.Z,force]\e[0m" unless new_version

  force = args[:force]&.to_s&.downcase == "force"

  dirty = `git status --porcelain`.strip
  abort "\e[31mAborting: working directory is not clean.\e[0m\n#{dirty}" unless dirty.empty?

  current = Phlex::Reactive::VERSION
  prerelease = new_version.match?(/alpha|beta|rc|pre/) || new_version == "pre"

  if new_version == "pre"
    new_version = current
    prerelease = true
  end

  tag = "v#{new_version}"
  version_file = "lib/phlex/reactive/version.rb"

  title = "Release #{tag}"
  title += " (force)" if force
  header title
  info "Current version: #{current}"
  info "New version:     #{new_version}"
  info "Pre-release:     #{prerelease}"

  # Step 0: Force cleanup — delete existing release and tag
  if force
    header "Force cleanup"
    if system("gh release view #{tag} >/dev/null 2>&1")
      sh("gh release delete #{tag} --yes --cleanup-tag")
      success "Deleted release and remote tag #{tag}"
    else
      skip "No release #{tag} to delete"
    end

    if system("git rev-parse #{tag} >/dev/null 2>&1")
      sh("git tag -d #{tag}")
      success "Deleted local tag #{tag}"
    else
      skip "No local tag #{tag} to delete"
    end
  end

  # Step 0b: PREFLIGHT the lockfiles — read and validate every one BEFORE a
  # single file is written. Validating inside Step 1b (after version.rb is
  # already bumped, and after an earlier lockfile may already be rewritten)
  # would abort into a DIRTY tree, which the clean-tree guard above then blocks
  # on the next run — a half-done release that cannot be retried without manual
  # cleanup. That is exactly the state v0.13.1's first attempt left behind, so
  # the check that can fail runs while failing is still free.
  #
  # Zero matches is not "already current": it means the file does not pin the
  # gem the way we think it does (a renamed gem, a changed lockfile format, a
  # file that never belonged in the list). Proceeding would ship version.rb
  # bumped against a lockfile still naming the old version — the stale-lockfile
  # release #247 exists to prevent, only silent.
  #
  # Matches the PATH-source spec ("    phlex-reactive (X.Y.Z)") and the
  # CHECKSUMS pin ("  phlex-reactive (X.Y.Z)"), leaving everything else
  # untouched. The DEPENDENCIES entry is the version-less "phlex-reactive!",
  # which carries no version and so is deliberately not matched.
  pin_pattern = /^(\s+phlex-reactive) \(([^)]*)\)$/
  lockfiles = %w[Gemfile.lock docs/Gemfile.lock].select { File.exist?(it) }
  locks = lockfiles.to_h { [it, File.read(it)] }
  locks.each do |lockfile, content|
    next unless content.scan(pin_pattern).empty?

    abort "\e[31mAborting: #{lockfile} contains no `phlex-reactive (X.Y.Z)` pin to bump.\e[0m\n" \
          "Either the lockfile format changed or this file does not pin the gem — fix it (or drop " \
          "it from the list in the release task) before releasing. Nothing has been modified."
  end

  # Step 1: Update version file
  header "Version"
  if new_version == current
    skip "Version already #{new_version}"
  else
    content = File.read(version_file)
    content.sub!(/VERSION = ".*"/, "VERSION = \"#{new_version}\"")
    File.write(version_file, content)
    success "Updated #{version_file}"
  end

  # Step 1b: Bump the pin in every tracked Gemfile.lock that carries this gem
  # via a local path — the root one (`gemspec` in ./Gemfile, committed since
  # #246) and the docs site's (`path: ".."`). Both carry the version string, so
  # bumping version.rb without them leaves a committed lockfile stale: the
  # Release workflow's frozen `bundle install` then refuses it ("gemspecs for
  # path gems changed, but the lockfile can't be updated because frozen mode is
  # set") and every fresh `bundle install` dirties the tree.
  #
  # The ONLY thing a version bump changes in these lockfiles is the path-gem
  # pin — so bump exactly that line, in place, with a string edit. We
  # deliberately do NOT run `bundle lock` (with or without --local): it is a
  # full re-resolve, and a re-resolve trips over constraints that have nothing
  # to do with this gem. Concretely, docs/Gemfile.lock declares Linux
  # PLATFORMS for the Kamal deploy, and `bundle lock --local` refuses to
  # resolve a platform gem like `thruster` for those against a Mac's installed
  # gems ("Could not find gems matching 'thruster' valid for all resolution
  # platforms") — which aborted v0.13.1's first attempt, mid-release, with
  # version.rb already bumped. It also re-resolves the WHOLE lock the moment a
  # Gemfile drifted from its lock, silently folding an unrelated dependency
  # jump into the release commit (pgbus was already stale-locked in docs/
  # exactly this way). pgbus's release task hit the same thruster failure and
  # made the same call. A targeted pin edit is deterministic on any machine,
  # needs no network and no installed gems, and yields the minimal diff: the
  # PATH spec line plus the CHECKSUMS line. Committed alongside the bump in
  # Step 3. Any OTHER tracked lockfile pinning the gem belongs in this list.
  header "Lockfiles"
  locks.each do |lockfile, content|
    pins = content.scan(pin_pattern)
    if pins.all? { |_prefix, version| version == new_version }
      # A genuine re-run after a partial failure: the pins ARE there and already
      # current. Distinguishable from the zero-pin case (which aborted in the
      # preflight) only because we counted rather than comparing strings.
      skip "#{lockfile} — #{pins.size} pin(s) already #{new_version}"
      next
    end

    File.write(lockfile, content.gsub(pin_pattern, "\\1 (#{new_version})"))
    success "Bumped #{pins.size} phlex-reactive pin(s) in #{lockfile}"
  end
  skip "No tracked lockfiles" if locks.empty?

  # Step 2: Verify gem builds cleanly
  header "Build verification"
  sh("gem build phlex-reactive.gemspec --strict")
  sh("rm -f phlex-reactive-*.gem")
  success "Gem builds cleanly"

  # Step 3: Commit the version bump + the re-locked lockfiles together, so a
  # release never leaves a stale/dirty committed lockfile behind. The guard fires
  # when EITHER the version file OR any lockfile changed (a re-run where only a
  # lockfile drifted — like v0.13.0's first attempt — still commits).
  header "Git commit"
  release_files = [version_file, *lockfiles]
  changed = release_files.any? do |f|
    !`git diff #{f}`.strip.empty? || !`git diff --cached #{f}`.strip.empty?
  end
  if changed
    sh("git add #{release_files.join(" ")}")
    sh("git commit -m 'chore: bump version to #{new_version}'")
    success "Committed version bump + lockfiles"
  else
    skip "Nothing to commit (version + lockfiles already current)"
  end

  # Step 4: Push to origin
  header "Git push"
  local_sha = `git rev-parse HEAD`.strip
  remote_sha = `git rev-parse origin/main 2>/dev/null`.strip
  if local_sha == remote_sha
    skip "origin/main already at #{local_sha[0..6]}"
  else
    sh("git push origin main")
    success "Pushed to origin/main"
  end

  # Step 5: Create release (the Release workflow publishes to RubyGems via OIDC)
  header "Release"
  tag_exists = system("git rev-parse #{tag} >/dev/null 2>&1")
  release_exists = system("gh release view #{tag} >/dev/null 2>&1")

  if release_exists
    skip "Release #{tag} already exists (use force to re-create)"
  elsif tag_exists
    info "Tag #{tag} exists, creating release from it"
    pre_flag = prerelease ? "--prerelease" : ""
    sh("gh release create #{tag} --generate-notes #{pre_flag}".strip)
    success "Release #{tag} created from existing tag"
  else
    pre_flag = prerelease ? "--prerelease" : ""
    sh("gh release create #{tag} --generate-notes --target main #{pre_flag}".strip)
    success "Release #{tag} created"
  end

  puts ""
  success "\e[1mRelease #{tag} complete!\e[0m CI will handle the rest:"
  puts "    • Run tests"
  puts "    • Build + verify gem"
  puts "    • Sign with Sigstore"
  puts "    • Publish to RubyGems (trusted publishing)"
  puts "    • Upload assets to the release"
end

namespace :dummy do
  desc "Run the dummy app for local QA (PORT=3010)"
  task :server do
    port = ENV.fetch("PORT", "3010")
    ENV["RAILS_ENV"] = "development"
    sh("bundle exec puma spec/dummy/config.ru -p #{port}")
  end
end

task default: %i[spec rubocop]
