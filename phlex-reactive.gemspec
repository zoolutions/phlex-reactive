# frozen_string_literal: true

require_relative "lib/phlex/reactive/version"

Gem::Specification.new do |spec|
  spec.name = "phlex-reactive"
  spec.version = Phlex::Reactive::VERSION
  spec.authors = ["Mikael Henriksson"]
  spec.email = ["mikael@mhenrixon.com"]

  spec.summary = "Reactive Phlex components for Rails — Livewire-style actions and live cross-tab updates, no Stimulus boilerplate."
  spec.description = <<~DESC
    phlex-reactive makes Phlex components reactive without writing Stimulus
    controllers or hand-picking Turbo Stream targets. Declare actions in Ruby;
    a single generic client runtime turns clicks and form input into a server
    round trip that re-renders the component and morphs it back in. Components
    self-target by a stable DOM id, so the same unit re-renders for client
    actions AND server-pushed broadcasts. State lives in the database behind a
    signed identity — no attacker-controlled snapshot. Pairs with pgbus for
    reliable, transactional, reconnect-safe live updates with no Action Cable
    and no Redis.
  DESC
  spec.homepage = "https://github.com/zoolutions/phlex-reactive"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.4.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/zoolutions/phlex-reactive/tree/main"
  spec.metadata["changelog_uri"] = "https://github.com/zoolutions/phlex-reactive/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  # List the gem's files. Prefer `git ls-files` (respects .gitignore), but fall
  # back to a Dir glob when git or the working tree is unavailable — e.g. when the
  # gem is a `path:` dependency in another app's Docker image that ships neither
  # git nor a .git directory. Bundler re-evaluates a path gem's gemspec on every
  # boot, so a hard git dependency here would crash the app at runtime.
  gem_files =
    begin
      tracked = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL, &:read)
      raise "git unavailable" if tracked.nil? || tracked.empty?

      tracked.split("\x0")
    rescue StandardError
      # Constrain the no-git fallback to the source files the gem actually ships
      # (.rb/.js/.erb under app|config|lib, the generator USAGE docs, the shipped
      # Claude skill under lib/**/*.md — issue #168, plus the three root docs), so
      # a glob in a dirty working tree can't sweep in machine-local artifacts
      # (logs, .env, tmp, editor backups). This keeps spec.files stable across
      # build environments without a hand-written manifest.
      patterns = %w[{app,config,lib}/**/*.{rb,js,erb,rake} lib/**/*.md lib/**/USAGE sig/**/*.rbs]
      patterns.flat_map { |p| Dir.glob(p, base: __dir__) }
        .select { |f| File.file?(File.join(__dir__, f)) } +
        %w[CHANGELOG.md LICENSE.txt README.md].select { |f| File.file?(File.join(__dir__, f)) }
    end

  # sig/ ships the RBS signatures of the public surface (issue #364).
  spec.files = gem_files.select do |f|
    f.start_with?("app/", "config/", "lib/", "sig/") ||
      %w[CHANGELOG.md LICENSE.txt README.md].include?(f)
  end
  spec.require_paths = ["lib"]

  spec.add_dependency "globalid", "~> 1.0"
  spec.add_dependency "phlex-rails", ">= 2.0", "< 3"
  spec.add_dependency "railties", ">= 7.1", "< 9.0"
  spec.add_dependency "turbo-rails", ">= 1.5", "< 3"
  spec.add_dependency "zeitwerk", "~> 2.6"
end
