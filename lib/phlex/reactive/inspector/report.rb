# frozen_string_literal: true

require "json"

module Phlex
  module Reactive
    module Inspector
      # Renders the Inspector's read-only inventory for the `phlex_reactive:actions`
      # and `phlex_reactive:find` rake tasks (issue #168). Plain text by default,
      # JSON when asked — the SAME no-ANSI posture as Doctor (clean CI/log
      # capture). Reports NAMES/paths/schemas only, never tokens/secrets/state.
      module Report
        module_function

        # A plain-text table of every component × action, or a JSON array when
        # `format` is :json. One row per action: component, action, params,
        # file:line, authorization heuristic.
        # `unverified_only:` keeps just the actions whose authorization_state is
        # :none (the review queue) and drops components left with none.
        def actions(components, format: :text, unverified_only: false)
          components = unverified(components) if unverified_only
          return actions_json(components) if format == :json

          actions_text(components)
        end

        # The find result: a ranked list header, then the TOP match in detail —
        # each action's params, source location, authorization heuristic, and the
        # full method-definition source. Empty message when nothing matched.
        def find(matches, query)
          return %(no component matched "#{query}") if matches.empty?

          lines = [%(#{matches.size} match#{"es" unless matches.size == 1} for "#{query}":)]
          matches.each { lines << "  #{it.name}" }
          lines << ""
          lines.concat(detail_lines(matches.first))
          lines.join("\n")
        end

        def unverified(components)
          components.filter_map do
            actions = it.actions.select { it.authorization_state == :none }
            it.with(actions:) if actions.any?
          end
        end

        # -- plain text -------------------------------------------------------

        def actions_text(components)
          return "no reactive components found" if components.empty?

          rows = components.flat_map { component_rows(it) }
          render_table(%w[COMPONENT ACTION PARAMS FILE:LINE AUTH], rows)
        end

        def component_rows(info)
          return [[info.name, "(no actions)", "", location_str(info.path), ""]] if info.actions.empty?

          info.actions.map do
            [info.name, it.name.to_s, params_str(it.params),
             location_str(it.source_location), auth_str(it)]
          end
        end

        # A minimal fixed-column table: each column padded to its widest cell.
        # No ANSI, no external dependency.
        def render_table(headers, rows)
          all = [headers] + rows
          # Two nested blocks (column index + row) need distinct named params —
          # `it` would collide, so name both.
          widths = headers.each_index.map { |col| all.map { |row| row[col].to_s.length }.max } # rubocop:disable Style/ItBlockParameter
          all.map { format_row(it, widths) }.join("\n")
        end

        def format_row(row, widths)
          row.each_with_index.map { |cell, i| cell.to_s.ljust(widths[i]) }.join("  ").rstrip
        end

        # -- find detail ------------------------------------------------------

        def detail_lines(info)
          lines = ["#{info.name}  (#{location_str(info.path)})"]
          lines << "  record: #{info.record_key}" if info.record_key
          lines << "  state:  #{info.state_keys.join(", ")}" if info.state_keys.any?
          lines << ""
          info.actions.each { lines.concat(action_detail(it)) }
          lines
        end

        def action_detail(action)
          header = "  action :#{action.name}"
          header += "  params: #{params_str(action.params)}" unless action.params.empty?
          header += "  (#{location_str(action.source_location)})  auth: #{auth_str(action)}"
          body = action.definition ? indent(action.definition) : "    (method not defined)"
          [header, body, ""]
        end

        def indent(text)
          text.each_line.map { "    #{it}" }.join.rstrip
        end

        # -- json -------------------------------------------------------------

        def actions_json(components)
          JSON.pretty_generate(components.map { component_hash(it) })
        end

        def component_hash(info)
          {
            component: info.name,
            path: location_str(info.path),
            record_key: info.record_key,
            state_keys: info.state_keys,
            actions: info.actions.map { action_hash(it) }
          }
        end

        def action_hash(action)
          {
            name: action.name,
            params: action.params,
            source_location: location_str(action.source_location),
            authorization_call_detected: action.authorization_call_detected?,
            authorization: action.authorization_state.to_s,
            authorization_skip: action.authorization_skip&.to_s
          }
        end

        # -- shared formatters ------------------------------------------------

        def params_str(params)
          params.empty? ? "" : params.inspect
        end

        # "file.rb:42", relative to Rails.root when possible. nil location (a
        # declared-but-missing method, or an unlocatable const) prints "?".
        def location_str(location)
          return "?" unless location

          file, line = location
          file = file.delete_prefix("#{::Rails.root}/") if defined?(::Rails) && ::Rails.root
          line ? "#{file}:#{line}" : file
        end

        # The authorization heuristic as a short label — advisory only.
        # "authorized*" (call detected), "skipped" / "skipped (class)" (declared
        # skip_verify_authorized), "unverified" (neither).
        def auth_str(action)
          case action.authorization_state
          when :detected then "authorized*"
          when :skipped then action.authorization_skip == :class ? "skipped (class)" : "skipped"
          else "unverified"
          end
        end
      end
    end
  end
end
