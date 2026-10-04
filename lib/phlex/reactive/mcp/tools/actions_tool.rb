# frozen_string_literal: true

module Phlex
  module Reactive
    module MCP
      module Tools
        # phlex_reactive_actions — the full action inventory: per action, the
        # declared param schema, source location, and the authorization heuristic.
        # Optional `component:` filter narrows to one component.
        class ActionsTool < BaseTool
          tool_name "phlex_reactive_actions"
          title "phlex-reactive actions"
          description <<~DESC
            The full reactive action inventory: for every component, each declared
            action with its param schema, source file:line, and a heuristic
            authorization status (whether an authorization method or
            mark_authorized! call was detected in the body — advisory only, since a
            helper may authorize indirectly), plus `authorization` — detected,
            skipped (declared skip_verify_authorized; `authorization_skip` says
            class or action) or none. Pass `component:` to scope to one
            component (exact name). Read-only — schemas and paths, never runtime
            values.
          DESC

          input_schema(
            properties: {
              component: {
                type: "string",
                description: "Exact component class name to scope to (e.g. \"CounterComponent\"). Omit for all."
              }
            },
            required: []
          )

          def self.call(component: nil, server_context: nil) # rubocop:disable Lint/UnusedMethodArgument
            eager_load_app!
            infos = Phlex::Reactive::Inspector.components
            infos = infos.select { it.name == component } if component
            json_response(components: infos.map { Phlex::Reactive::Inspector::Report.component_hash(it) })
          end
        end
      end
    end
  end
end
