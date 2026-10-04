# frozen_string_literal: true

require "prism"

module Phlex
  module Reactive
    # The ONE read-only introspection layer (issue #168), consumed by the rake
    # tasks (`phlex_reactive:actions` / `find`), the MCP tools, and Doctor. It
    # discovers every constant-backed reactive component from the loaded
    # Streamable registry and, per declared action, its param schema, source
    # location, full method-definition source (extracted with Prism), and a
    # heuristic authorization status.
    #
    # It reports NAMES, PATHS, and declared SCHEMAS only — never tokens, secrets,
    # or runtime state (the instrumentation privacy contract extended to
    # tooling). Like Doctor, it is READ-ONLY: it never mounts a component,
    # mutates state, or touches the default-deny boundary.
    #
    #   Phlex::Reactive::Inspector.components   # => [ComponentInfo]
    #   Phlex::Reactive::Inspector.find(query)  # => ranked [ComponentInfo]
    module Inspector
      # One declared action's introspection.
      #
      #   * source_location — klass.instance_method(name).source_location, or nil
      #                       when the action is declared but the method is
      #                       missing (the endpoint would 500 on public_send).
      #   * definition      — the full `def ... end` source, extracted with Prism.
      #                       nil when the method is missing or its file is
      #                       unreadable/unparseable (degrade, never raise).
      #   * authorization_call_detected? — a HEURISTIC: true when the Prism scan
      #                       of the definition finds a call to any configured
      #                       authorization method or mark_authorized!. A helper
      #                       may authorize indirectly, so this is advisory ONLY.
      #   * authorization_skip — :class (a bare skip_verify_authorized, own or
      #                       inherited), :action (this action is named in one),
      #                       or nil. The author's declared opt-out (issue #278).
      ActionInfo = Data.define(:name, :params, :source_location, :definition, :authorization_skip) do
        # Was any authorization method (or mark_authorized!) called directly in
        # the method body? Heuristic — a Prism scan of `definition`. False when
        # the definition is unavailable.
        def authorization_call_detected?
          return false unless definition

          Inspector.authorization_call?(definition)
        end

        # :detected (a call was found), :skipped (declared skip_verify_authorized)
        # or :none (neither — the review queue). A detected call wins over a skip.
        def authorization_state
          return :detected if authorization_call_detected?

          authorization_skip ? :skipped : :none
        end
      end

      # One reactive component's introspection.
      #
      #   * path        — Object.const_source_location(name) => [file, line].
      #   * record_key  — the declared reactive_record key, or nil.
      #   * state_keys  — the declared reactive_state keys.
      #   * actions     — [ActionInfo], one per declared action.
      ComponentInfo = Data.define(:klass, :name, :path, :record_key, :state_keys, :actions)

      # The authorization method names the heuristic looks for. Reads
      # Phlex::Reactive.authorization_methods when configured (issue #168 phase 2);
      # otherwise the common set (Pundit/CanCanCan/ActionPolicy-style). The manual
      # escape hatch `mark_authorized!` always counts.
      DEFAULT_AUTHORIZATION_METHODS = %i[authorize! authorize allowed_to?].freeze
      MANUAL_AUTHORIZATION_MARK = :mark_authorized!

      class << self
        # Every constant-backed reactive component, as [ComponentInfo]. Call
        # Rails.application.eager_load! first (the caller / rake task does) so
        # every app component is in the Streamable registry.
        def components
          reactive_component_classes.map { component_info(it) }
        end

        # Ranked fuzzy matches for `query` (issue #168). Scored on BOTH the
        # demodulized and the full namespaced name, best of the two:
        # exact > prefix > substring > subsequence, case-insensitive. Returns []
        # on no match. No dependency — a ~1-screen scorer.
        def find(query)
          q = query.to_s.downcase
          return [] if q.empty?

          reactive_component_classes
            .filter_map { score_component(it, q) }
            .sort_by { |score, name, _klass| [-score, name] }
            .map { |_score, _name, klass| component_info(klass) }
        end

        # True when a component class is a real, CONSTANT-RESOLVABLE reactive
        # component — its own name round-trips through safe_constantize (exactly
        # how ActionsController#resolve_component rebuilds it from the token). This
        # also excludes anonymous classes (name nil) and fixtures that fake
        # `def self.name` without a matching constant. Moved here from Doctor
        # (issue #168); Doctor delegates.
        def constant_backed_component?(klass)
          reactive_component?(klass) && klass.name && klass.name.safe_constantize.equal?(klass)
        rescue StandardError
          false
        end

        def reactive_component?(klass)
          klass.respond_to?(:reactive_actions) && klass.include?(Phlex::Reactive::Component)
        rescue StandardError
          false
        end

        # Does the method-definition source `definition` call an authorization
        # method or mark_authorized! anywhere? A Prism scan for a call node whose
        # method name is in the configured set. Heuristic; degrades to false on
        # an unparseable snippet.
        def authorization_call?(definition)
          result = Prism.parse(definition)
          return false unless result.success?

          names = authorization_method_names
          # Set#intersect? on the Set receiver (names) — Array#intersect? would raise
          # TypeError on a Set arg (caught by the rescue below → a silent false, the
          # bug the naive Style/ArrayIntersect autocorrect introduces). Set#intersect?
          # accepts any Enumerable, so the call_names Array is a valid argument.
          names.intersect?(call_names(result.value))
        rescue StandardError
          false
        end

        # The configured authorization method names plus the manual mark, as a
        # Set of symbols. Reads Phlex::Reactive.authorization_methods when it
        # exists (phase 2), else the default set. Guarded: a misconfigured
        # authorization_methods (nil, or a single symbol) is coerced through
        # Array() rather than raising `.map` on nil — which the caller's rescue
        # would swallow, silently disabling the heuristic instead of surfacing it.
        def authorization_method_names
          configured =
            if Phlex::Reactive.respond_to?(:authorization_methods)
              Phlex::Reactive.authorization_methods || DEFAULT_AUTHORIZATION_METHODS
            else
              DEFAULT_AUTHORIZATION_METHODS
            end
          (Array(configured).map(&:to_sym) + [MANUAL_AUTHORIZATION_MARK]).to_set
        end

        private

        def reactive_component_classes
          Phlex::Reactive::Streamable.registered_classes.select { constant_backed_component?(it) }
        end

        def component_info(klass)
          ComponentInfo.new(
            klass:,
            name: klass.name,
            path: Object.const_source_location(klass.name),
            record_key: (klass.reactive_record_key if klass.respond_to?(:reactive_record_key)),
            state_keys: state_keys_for(klass),
            actions: action_infos(klass)
          )
        rescue StandardError
          ComponentInfo.new(klass:, name: klass.name, path: nil, record_key: nil, state_keys: [], actions: [])
        end

        def state_keys_for(klass)
          klass.respond_to?(:reactive_state_keys) ? klass.reactive_state_keys : []
        end

        def action_infos(klass)
          klass.reactive_actions.values.map { action_info(klass, it) }
        end

        def action_info(klass, action)
          location = method_location(klass, action.name)
          ActionInfo.new(
            name: action.name,
            params: action.params,
            source_location: location,
            definition: (extract_definition(location) if location),
            authorization_skip: authorization_skip(klass, action.name)
          )
        end

        # How `name` opts out of verify_authorized: :class for a bare skip (own
        # or inherited), :action when listed by name, else nil. Resolved through
        # the same Registry readers the runtime guard uses.
        def authorization_skip(klass, name)
          return :class if klass.reactive_skip_all_authorization?

          :action if klass.reactive_skip_authorization_actions.include?(name.to_sym)
        end

        # The method's [file, line], or nil when the declared method is missing
        # (an undeclared/typo'd action — the endpoint would 500 on public_send).
        def method_location(klass, name)
          return nil unless klass.method_defined?(name) || klass.private_method_defined?(name)

          klass.instance_method(name).source_location
        rescue StandardError
          nil
        end

        # The full `def ... end` source at [file, line], via Prism. Finds the def
        # node whose location spans `line` and returns its slice. nil when the
        # file is unreadable/unparseable or no def node covers the line — never
        # raises.
        def extract_definition(location)
          file, line = location
          return nil unless file && line && File.readable?(file)

          result = Prism.parse_file(file)
          return nil unless result.success?

          node = def_node_at(result.value, line)
          node&.slice
        rescue StandardError
          nil
        end

        # Depth-first search for the DefNode whose source line == `line`.
        def def_node_at(node, line)
          return node if def_node_on_line?(node, line)

          node.compact_child_nodes.each do
            found = def_node_at(it, line)
            return found if found
          end
          nil
        end

        def def_node_on_line?(node, line)
          node.is_a?(Prism::DefNode) && node.location.start_line == line
        end

        # Every method name called anywhere under `node` (a Prism CallNode's
        # name), depth-first. Used by the authorization heuristic.
        def call_names(node, acc = [])
          acc << node.name if node.is_a?(Prism::CallNode)
          node.compact_child_nodes.each { call_names(it, acc) }
          acc
        end

        # -- fuzzy scoring ----------------------------------------------------

        # The best match score of the demodulized and full names, or nil if
        # neither matches. Higher is better; ties broken by name in .find.
        def score_component(klass, query)
          full = klass.name.downcase
          demodulized = klass.name.split("::").last.downcase
          score = [match_score(demodulized, query), match_score(full, query)].compact.max
          return nil unless score

          [score, klass.name, klass]
        end

        # exact 4 > prefix 3 > substring 2 > subsequence 1 > no match nil.
        def match_score(candidate, query)
          return 4 if candidate == query
          return 3 if candidate.start_with?(query)
          return 2 if candidate.include?(query)
          return 1 if subsequence?(candidate, query)

          nil
        end

        # Are the characters of `query` present in `candidate` in order (gaps
        # allowed)? The loosest fuzzy tier.
        def subsequence?(candidate, query)
          i = 0
          candidate.each_char do
            i += 1 if it == query[i]
            return true if i == query.length
          end
          query.empty?
        end
      end
    end
  end
end
