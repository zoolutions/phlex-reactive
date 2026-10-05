# frozen_string_literal: true

module Phlex
  module Reactive
    # Validates a phlex-reactive install and reports ✓/✗/? per check with a fix
    # for each failure (issue #106). Five closed issues (#3 boot/eager-load, #26
    # route shadowing, #42 lost request, #48 unregistered controller, #57
    # importmap 404) were pure integration papercuts that only surfaced AFTER
    # something already broke. The doctor turns "nothing happens, why?" into an
    # actionable checklist you run before/after setup:
    #
    #   bin/rails phlex_reactive:doctor
    #
    # Every check is a small object answering [status, message, fix]. It is
    # READ-ONLY — it never mounts a component, mutates state, or touches the
    # default-deny boundary; the worst it does is a throwaway sign→verify round
    # trip and (for the component checks) iterate the loaded Streamable registry.
    class Doctor
      # The result of one check: a status (:ok/:fail/:unknown), a human message,
      # and (on anything but :ok) a fix line telling the adopter what to do. A
      # plain value object (not Data) so it takes positional status/message plus
      # keyword name:/fix: — the shape the check builders and specs construct.
      class Check
        attr_reader :name, :status, :message, :fix

        def initialize(status, message, name: nil, fix: nil)
          @name = name
          @status = status
          @message = message
          @fix = fix
        end

        def ok? = status == :ok
        def fail? = status == :fail
        def unknown? = status == :unknown
      end

      # Glyphs are plain ASCII-safe Unicode with NO ANSI color, so CI/log capture
      # reads cleanly (issue #106 acceptance: stable plain-text output).
      GLYPHS = { ok: "✓", fail: "✗", unknown: "?" }.freeze

      # The entrypoint the rake task calls: eager-load so the component registry
      # is populated, print the report, and return TRUE when nothing failed (an
      # advisory `?` doesn't count) so a caller can gate its exit code on it.
      # (Not a predicate name — this is the imperative "run + report" action that
      # happens to return a success boolean; `io` is the conventional stream name.)
      def self.run(io: $stdout) # rubocop:disable Naming/PredicateMethod,Naming/MethodParameterName
        ::Rails.application.eager_load! if defined?(::Rails) && ::Rails.application
        doctor = new
        io.puts(doctor.report)
        !doctor.failures?
      end

      # Run every check and return the ordered list of Check objects, memoized so
      # report + failures? share one pass. The caller (or Doctor.run) is
      # responsible for eager_load! so component classes are in the registry —
      # the component checks are empty otherwise.
      def checks
        @checks ||= build_checks
      end

      # True when any check FAILED (a hard ✗). Advisory `?` lines are not
      # failures — a Phlex-layout app legitimately can't verify csrf that way.
      def failures?
        checks.any?(&:fail?)
      end

      def build_checks
        components = registered_components
        [
          route_check,
          defer_route_check,
          fragment_route_check,
          fragment_path_meta_check,
          stimulus_check,
          csrf_check,
          verifier_check,
          base_controller_check,
          action_check(components),
          id_check(components),
          authorization_check(components),
          dormant_check(components),
          *early_pin_check(components)
        ].compact
      end

      # --- individual checks ------------------------------------------------

      # Does POST <action_path> resolve to the gem's ActionsController? A host
      # catch-all route shadows it otherwise (issue #26). Reuses the shipped
      # guard verbatim — it already handles routes-not-yet-drawn.
      def route_check
        path_check(Phlex::Reactive.action_path, :route, "Phlex::Reactive.action_path")
      end

      # Same shadow class for the defer endpoint (issue #165): a shadowed defer
      # route makes every reply.defer / reactive_lazy fetch 404 — the pending
      # marker clears into data-reactive-error="defer" client-side, but the
      # root cause is invisible without this check.
      def defer_route_check
        path_check(Phlex::Reactive.defer_path, :defer_route, "Phlex::Reactive.defer_path")
      end

      # The cacheable-fragment GET endpoint (issue #277): a host GET catch-all
      # that shadows it makes every `reactive_lazy cache:` fetch load the host's
      # fallback page instead of the fragment.
      def fragment_route_check
        path = "#{Phlex::Reactive.fragment_path}/:id"
        if Phlex::Reactive.fragment_route_ok?
          Check.new(:ok, "GET #{path} routes to phlex/reactive/fragments", name: :fragment_route)
        else
          Check.new(:fail, "GET #{path} does not resolve to phlex/reactive/fragments", name: :fragment_route,
            fix: "A host catch-all route (get \"*path\", ...) likely shadows it. Exempt " \
                 "#{Phlex::Reactive.fragment_path.delete_prefix("/")} from the catch-all, or set " \
                 "Phlex::Reactive.fragment_path to an unshadowed path.")
        end
      end

      # A custom fragment_path the client was never told about (issue #277): the
      # client only fetches a fragment URL under the path it knows — the meta
      # tag, else the default — so every `reactive_lazy cache:` shell would be
      # refused (reactive:error, the shell never loads). Only checked when the
      # path was changed; nil (no check) otherwise.
      def fragment_path_meta_check
        path = Phlex::Reactive.fragment_path
        return if path == "/reactive/fragment"

        # A file must name the meta AND supply this path — literally, or from
        # the setting (`Phlex::Reactive.fragment_path`). A tag left behind with
        # an old path is as broken as none. Whether it sits in <head> (the only
        # place the client reads it) can't be told from source; the fix says so.
        if layout_references?("phlex-reactive-fragment-path") { it.include?(path) || it.include?("fragment_path") }
          Check.new(:ok, "phlex-reactive-fragment-path meta found for #{path} (it must be in <head>)",
            name: :fragment_path_meta)
        else
          Check.new(:fail, "Phlex::Reactive.fragment_path is #{path} but no layout renders its meta tag with that path",
            name: :fragment_path_meta,
            fix: "Add <meta name=\"phlex-reactive-fragment-path\" content=\"#{path}\"> to your layout's " \
                 "<head> — the client refuses a fragment URL outside the path it knows.")
        end
      end

      # Shared body for the two endpoint-route checks: both POST to the gem's
      # ActionsController, so action_route_ok? answers for either path.
      def path_check(path, name, setting)
        if Phlex::Reactive.action_route_ok?(path)
          Check.new(:ok, "POST #{path} routes to #{Doctor.actions_controller}", name: name)
        else
          Check.new(:fail, "POST #{path} does not resolve to #{Doctor.actions_controller}", name: name,
            fix: "A host catch-all route (match \"*path\", ...) likely shadows it. Exempt " \
                 "#{path.delete_prefix("/")} from the catch-all, or set #{setting} " \
                 "to an unshadowed path.")
        end
      end

      # Is the generic `reactive` controller registered in a Stimulus entrypoint
      # (issue #48)? Grep the candidate entrypoints for the register line; when
      # importmap is present, additionally verify the pin resolves.
      def stimulus_check
        entrypoint = stimulus_registration_files.find { registers_reactive?(it) }
        return stimulus_missing_check unless entrypoint

        if importmap_pin_broken?
          return Check.new(:fail, "reactive registered in #{relative(entrypoint)}, but the importmap " \
                                  "pin for phlex/reactive/reactive_controller is missing", name: :stimulus,
            fix: "The engine auto-pins it; if you overrode config/importmap.rb, add:\n  " \
                 "pin \"phlex/reactive/reactive_controller\"")
        end

        Check.new(:ok, "reactive controller registered in #{relative(entrypoint)}", name: :stimulus)
      end

      # ADVISORY only (issue #106): grep ERB layouts AND Phlex layout files for a
      # csrf_meta_tags reference. A hard fail would false-flag Phlex-layout apps
      # (this gem's core audience), so a miss is :unknown, never :fail.
      def csrf_check
        if csrf_meta_referenced?
          Check.new(:ok, "csrf_meta_tags found in a layout", name: :csrf)
        else
          Check.new(:unknown, "could not verify csrf_meta_tags in a layout", name: :csrf,
            fix: "Confirm your layout renders csrf_meta_tags (ERB: <%= csrf_meta_tags %>; " \
                 "Phlex: render Phlex::Rails::Helpers::CSRFMetaTags or emit the meta tags) — " \
                 "the client reads the CSRF token from <meta name=\"csrf-token\">.")
        end
      end

      # A throwaway sign→verify round trip proves the verifier is configured and
      # the key round-trips (a bad secret_key_base or a purpose mismatch fails).
      # verify legitimately stamps the version key "v" (issue #111), so we check
      # the original entries survived rather than exact equality.
      def verifier_check
        payload = { "c" => "Phlex::Reactive::Doctor", "probe" => true }
        roundtripped = Phlex::Reactive.verify(Phlex::Reactive.sign(payload))
        if roundtripped && payload.all? { |k, v| roundtripped[k] == v }
          Check.new(:ok, "identity verifier signs and verifies", name: :verifier)
        else
          Check.new(:fail, "identity verifier did not round-trip a probe payload", name: :verifier,
            fix: "Check secret_key_base is set, or configure a dedicated " \
                 "Phlex::Reactive.verifier = ActiveSupport::MessageVerifier.new(key).")
        end
      rescue => e # rubocop:disable Style/RescueStandardError
        Check.new(:fail, "identity verifier raised: #{e.message}", name: :verifier,
          fix: "Set secret_key_base, or configure Phlex::Reactive.verifier explicitly.")
      end

      # Does Phlex::Reactive.base_controller_name constantize (issue #48-adjacent)?
      def base_controller_check
        name = Phlex::Reactive.base_controller_name
        klass = Phlex::Reactive.base_controller
        Check.new(:ok, "base_controller_name #{name} constantizes to #{klass}", name: :base_controller)
      rescue => e # rubocop:disable Style/RescueStandardError
        Check.new(:fail, "base_controller_name #{Phlex::Reactive.base_controller_name.inspect} " \
                         "does not constantize (#{e.class})", name: :base_controller,
          fix: "Set Phlex::Reactive.base_controller_name to a controller that exists " \
               "(e.g. \"ApplicationController\").")
      end

      # Every declared `action :name` must have a public instance method (mirrors
      # the endpoint's public_send dispatch — a missing one 500s at click).
      def action_check(components)
        missing = components.flat_map { missing_action_methods(it) }
        return Check.new(:ok, "every declared action has a public method", name: :actions) if missing.empty?

        Check.new(:fail, "declared actions with no matching public method: #{missing.join(", ")}", name: :actions,
          fix: "Define a public method for each, or remove the `action :name` declaration.")
      end

      # Flag a class that would raise NotImplementedError in #id at render: it
      # inherits Streamable's default #id AND is NOT record-backed. A record-backed
      # class on the default is FINE — that default shipped in #81.
      def id_check(components)
        offenders = components.select { default_id_without_record?(it) }.map(&:name)
        return Check.new(:ok, "every component resolves a stable #id", name: :ids) if offenders.empty?

        Check.new(:fail, "state-backed components with no #id (render raises NotImplementedError): " \
                         "#{offenders.join(", ")}", name: :ids,
          fix: "Add `def id = \"my-thing\"` to each — a state-backed component has no record to " \
               "derive a default id from.")
      end

      # ADVISORY (issue #168): the presence-side static heuristic complementing
      # the runtime verify_authorized guard. Flags a non-skipped action whose
      # component defines NONE of Phlex::Reactive.authorization_methods anywhere
      # in its ancestry AND whose body (Prism-scanned via the Inspector) makes no
      # authorization / mark_authorized! call. It is :unknown, NEVER a hard fail:
      # a helper may authorize indirectly, so this is a hint, not a verdict.
      def authorization_check(components)
        suspects = components.flat_map { unauthorized_action_labels(it) }
        return Check.new(:ok, "every mutating action appears to authorize", name: :authorization) if suspects.empty?

        Check.new(:unknown, "actions with no detected authorization call: #{suspects.join(", ")}",
          name: :authorization,
          fix: "This is a heuristic (a helper may authorize indirectly). If each is intentional, " \
               "confirm it authorizes; if an action is genuinely public, declare " \
               "`skip_verify_authorized`. See the Debugging & tooling docs page.")
      end

      # Dormant roots (issue #274): how many components declare `reactive_dormant`
      # and whether a Stimulus entrypoint imports phlex/reactive/early — the
      # module that wakes them (without it a dormant root never mounts). No line
      # at all when nothing is dormant. ADVISORY when the import isn't found: it
      # may live in a file the doctor doesn't scan. A per-render
      # reactive_root(dormant: true) is invisible here (it isn't a declaration).
      def dormant_check(components, early: imports_early?)
        dormant = dormant_components(components)
        return if dormant.empty?

        label = "#{dormant.size} dormant #{dormant.one? ? "component" : "components"} (#{dormant.map(&:name).join(", ")})"
        return Check.new(:ok, "#{label}; phlex/reactive/early is imported#{early_location(early)}", name: :dormant) if early

        Check.new(:unknown, "#{label}, but no import of phlex/reactive/early was found", name: :dormant,
          fix: "A dormant root is woken by that module — without it the root never mounts. Add to " \
               "your entrypoint, before any controller loads:\n  import \"phlex/reactive/early\"")
      end

      # Every import map the app registers must pin phlex/reactive/early when a
      # dormant root exists (issue #307): a map without the pin cannot resolve
      # the specifier, so the import fails on the pages that map serves. One
      # advisory check per map lacking the pin; none when every map has it.
      # Maps: Rails.application.importmap, or Phlex::Reactive.importmaps (a
      # callable returning { name => Importmap::Map }) for an app with its own.
      def early_pin_check(components)
        return [] if dormant_components(components).empty?

        import_maps.filter_map do |name, map|
          next if map_pins_early?(map)

          Check.new(:unknown, "import map \"#{name}\" does not pin phlex/reactive/early", name: :early_pin,
            fix: "A dormant root rendered on a page served by this map cannot load the module. Add to " \
                 "the map's file:\n  pin \"phlex/reactive/early\", to: \"phlex/reactive/early.min.js\", preload: true")
        end
      end

      # --- rendering --------------------------------------------------------

      # The full plain-text report: a line per check, plus an indented fix under
      # each non-passing one. No ANSI color (clean CI/log capture).
      def report
        lines = ["phlex-reactive doctor", ""]
        results = checks
        results.each { lines << render_check(it) }
        lines << ""
        lines << summary_line(results)
        lines.join("\n")
      end

      # One check as "✓/✗/? message" plus an indented "→ fix" when it isn't ok.
      def render_check(check)
        line = "#{GLYPHS.fetch(check.status)} #{check.message}"
        line += "\n    → #{check.fix}" if check.fix && !check.ok?
        line
      end

      def self.actions_controller
        "phlex/reactive/actions"
      end

      STIMULUS_ENTRYPOINTS = %w[
        app/javascript/controllers/index.js
        app/javascript/controllers/application.js
        app/javascript/application.js
      ].freeze
      EARLY_IMPORT = %r{import\s+["']phlex/reactive/early["']}
      # Closed comments, which may span lines: HTML, JS block and ERB.
      BLOCK_COMMENT = %r{<!--.*?-->|/\*.*?\*/|<%#.*?%>}m
      # What precedes the import on its line when it is commented out: a //
      # (not the one in a URL), an unclosed /*, or a block-comment's leading *.
      COMMENT_BEFORE = %r{(?<!:)//|/\*|\A\s*\*}

      # Is there an `import "phlex/reactive/early"` in `source` that actually
      # runs? Closed comments are dropped first, then each line is read, so a
      # commented-out import doesn't count.
      def self.imports_early_source?(source)
        source.gsub(BLOCK_COMMENT, "").each_line.any? do
          (match = EARLY_IMPORT.match(it)) && !match.pre_match.match?(COMMENT_BEFORE)
        end
      end

      private

      # A one-line tally: how many passed, failed, and are advisory/unknown.
      def summary_line(results)
        passed = results.count(&:ok?)
        failed = results.count(&:fail?)
        advisory = results.count(&:unknown?)
        parts = ["#{passed} passed"]
        parts << "#{failed} failed" if failed.positive?
        parts << "#{advisory} advisory" if advisory.positive?
        parts.join(", ")
      end

      # The registry filtered to real, CONSTANT-RESOLVABLE reactive components.
      # A class is only invokable by the endpoint if its own name round-trips
      # through safe_constantize (that's exactly how ActionsController#resolve_component
      # rebuilds it from the token). So we validate only classes where
      # name.safe_constantize is the class itself — which also excludes anonymous
      # classes (name nil) and test fixtures that fake `def self.name` without a
      # matching constant, keeping the whole-app scan honest.
      #
      # The predicate lives in Inspector (issue #168) — the one read layer shared
      # by the rake tasks, the MCP tools, and this Doctor — so it stays in sync
      # with resolve_component's rebuild path in exactly one place.
      def registered_components
        Phlex::Reactive::Streamable.registered_classes.select { constant_backed_component?(it) }
      end

      def constant_backed_component?(klass)
        Phlex::Reactive::Inspector.constant_backed_component?(klass)
      end

      def reactive_component?(klass)
        Phlex::Reactive::Inspector.reactive_component?(klass)
      end

      # "Klass#action" for every declared action on `klass` that has no public
      # method to dispatch to. Kept as its own method (not a nested block) so the
      # class is a named method arg, not a shadowed `it`.
      def missing_action_methods(klass)
        klass.reactive_actions.keys
          .reject { klass.public_method_defined?(it) }
          .map { "#{klass}##{it}" }
      end

      # True when the class still uses Streamable's default #id AND has no record
      # to back it (so the default raises). owner == Streamable means no override.
      def default_id_without_record?(klass)
        klass.instance_method(:id).owner == Phlex::Reactive::Streamable &&
          !(klass.respond_to?(:reactive_record_key) && klass.reactive_record_key)
      rescue StandardError
        false
      end

      # "Klass#action" for every declared action on `klass` that (advisory)
      # appears unauthorized: the component defines no authorization method in its
      # ancestry, the action isn't skipped, and the Prism scan (via the shared
      # Inspector) finds no authorization / mark_authorized! call in its body.
      def unauthorized_action_labels(klass)
        return [] if component_defines_authorization_method?(klass)

        info = Phlex::Reactive::Inspector.components.find { it.klass == klass }
        return [] unless info

        info.actions
          .reject { skips_authorization?(klass, it.name) }
          .reject(&:authorization_call_detected?)
          .map { "#{klass}##{it.name}" }
      rescue StandardError
        []
      end

      # Does the class define any CONFIGURED authorization method anywhere in its
      # ancestry (public or private)? If so, it plausibly authorizes through a
      # helper the static scan can't follow — stay quiet. Deliberately reads
      # Phlex::Reactive.authorization_methods and NOT the Inspector's set, which
      # folds in mark_authorized! — every component inherits that instance helper,
      # so including it would silence the check for everything.
      def component_defines_authorization_method?(klass)
        Phlex::Reactive.authorization_methods.any? do
          klass.method_defined?(it) || klass.private_method_defined?(it)
        end
      rescue StandardError
        false
      end

      def skips_authorization?(klass, action_name)
        klass.respond_to?(:skip_verify_authorized?) && klass.skip_verify_authorized?(action_name)
      end

      def stimulus_missing_check
        Check.new(:fail, "the reactive controller is not registered in any Stimulus entrypoint", name: :stimulus,
          fix: "Add to your entrypoint (e.g. app/javascript/controllers/index.js):\n  " \
               "import ReactiveController from \"phlex/reactive/reactive_controller\"\n  " \
               "application.register(\"reactive\", ReactiveController)\n" \
               "or re-run: bin/rails generate phlex:reactive:install")
      end

      # Files that may hold the register line: the JS entrypoint candidates,
      # importmap-style AND esbuild/bun (issue #106) — controllers/index.js,
      # controllers/application.js, application.js — PLUS ERB layouts, since a
      # small/importmap app often registers inline in <head> rather than in a
      # dedicated entrypoint file. Only existing files are returned.
      def stimulus_registration_files
        candidates = STIMULUS_ENTRYPOINTS.map { app_path(it) }
        candidates += ::Dir.glob(app_path("app/views/layouts/**/*.erb"))
        candidates.select { File.exist?(it) }
      end

      def registers_reactive?(path)
        File.read(path).include?('application.register("reactive", ReactiveController)')
      rescue StandardError
        false
      end

      # The relative path of the first file that imports phlex/reactive/early,
      # or false. The Stimulus registration files go first, then every other app
      # JavaScript entry (vendor excluded) and inline module scripts in views and
      # components (issue #307).
      def imports_early?
        (stimulus_registration_files | early_import_candidates).each do
          return relative(it) if Doctor.imports_early_source?(early_source(it))
        rescue StandardError
          next
        end
        false
      end

      # A Ruby file's `# …` comment lines are not code (a layout that mentions
      # the import in a comment must not pass the check).
      def early_source(path)
        source = File.read(path)
        path.end_with?(".rb") ? source.lines.grep_v(/\A\s*#/).join : source
      end

      def early_import_candidates
        globs = %w[app/javascript/**/*.js app/views/**/*.{rb,erb} app/components/**/*.{rb,erb}].map { app_path(it) }
        ::Dir.glob(globs).reject { it.include?("/vendor/") }.sort
      end

      # " (path)" when the import sits outside the JavaScript entrypoints the
      # doctor always scanned (those keep their original output).
      def early_location(early)
        return "" unless early.is_a?(String)
        return "" if STIMULUS_ENTRYPOINTS.include?(early)

        " (#{early})"
      end

      def dormant_components(components)
        components.select { it.respond_to?(:reactive_dormant?) && it.reactive_dormant? }
      end

      def import_maps
        configured = Phlex::Reactive.importmaps&.call
        return configured if configured

        map = ::Rails.application.respond_to?(:importmap) ? ::Rails.application.importmap : nil
        map ? { "application" => map } : {}
      end

      def map_pins_early?(map)
        map.packages.key?("phlex/reactive/early")
      end

      # Only meaningful when importmap is in use. True when importmap is present
      # but the reactive_controller pin is absent (the engine pins it, so this is
      # really "someone overrode importmap.rb and dropped the pin").
      def importmap_pin_broken?
        return false unless defined?(::Importmap) && ::Rails.application.respond_to?(:importmap)

        map = ::Rails.application.importmap
        return false unless map

        !map.packages.key?("phlex/reactive/reactive_controller")
      rescue StandardError
        false
      end

      # Grep ERB layouts AND Phlex layout files for a csrf_meta_tags reference.
      def csrf_meta_referenced?
        layout_references?("csrf_meta_tags")
      end

      # Does any ERB view / Phlex view or component mention `needle` (and, with
      # a block, satisfy it for that file's source)?
      def layout_references?(needle)
        globs = %w[
          app/views/**/*.erb
          app/views/**/*.rb
          app/components/**/*.rb
          app/views/**/layout*.html*
        ].map { app_path(it) }

        ::Dir.glob(globs).any? do
          source = File.read(it)
          source.include?(needle) && (!block_given? || yield(source))
        rescue StandardError
          false
        end
      rescue StandardError
        false
      end

      def app_path(relative)
        ::Rails.root.join(relative).to_s
      end

      def relative(path)
        return path unless defined?(::Rails) && ::Rails.root

        path.delete_prefix("#{::Rails.root}/")
      end
    end
  end
end
