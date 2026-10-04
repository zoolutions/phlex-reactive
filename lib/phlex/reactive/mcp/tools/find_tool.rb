# frozen_string_literal: true

module Phlex
  module Reactive
    module MCP
      module Tools
        # phlex_reactive_find — fuzzy-search components by name and return the
        # ranked matches, each with full per-action detail INCLUDING the Prism-
        # extracted method definition source. The tool for "where is X defined and
        # what does its action do?".
        class FindTool < BaseTool
          tool_name "phlex_reactive_find"
          title "phlex-reactive find"
          description <<~DESC
            Fuzzy-find reactive components by name (exact > prefix > substring >
            subsequence, on both the demodulized and full name). Returns the ranked
            matches, each with its actions' param schema, source location,
            authorization heuristic, and the full method-definition SOURCE
            (extracted with Prism). Read-only.

            NOTE: unlike the other tools (which report names/paths/schemas only),
            this one returns the action's source code verbatim — so anything
            hardcoded in an action body is surfaced too. Don't embed secrets or
            credentials in action definitions (read them from ENV/credentials).
          DESC

          input_schema(
            properties: {
              query: { type: "string", description: "The search string (component name fragment)." }
            },
            required: ["query"]
          )

          def self.call(query:, server_context: nil) # rubocop:disable Lint/UnusedMethodArgument
            eager_load_app!
            matches = Phlex::Reactive::Inspector.find(query).map { match_hash(it) }
            json_response(query: query, matches: matches)
          end

          def self.match_hash(info)
            {
              name: info.name,
              path: Phlex::Reactive::Inspector::Report.location_str(info.path),
              record_key: info.record_key,
              state_keys: info.state_keys,
              actions: info.actions.map { action_detail(it) }
            }
          end

          def self.action_detail(action)
            {
              name: action.name,
              params: action.params,
              source_location: Phlex::Reactive::Inspector::Report.location_str(action.source_location),
              authorization_call_detected: action.authorization_call_detected?,
              authorization: action.authorization_state.to_s,
              authorization_skip: action.authorization_skip&.to_s,
              # The full method SOURCE — this is the one field that exposes an
              # action body verbatim (see the tool description). A secret hardcoded
              # in an action would surface here; keep secrets out of action bodies.
              definition: action.definition
            }
          end
        end
      end
    end
  end
end
