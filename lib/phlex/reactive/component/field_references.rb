# frozen_string_literal: true

module Phlex
  module Reactive
    module Component
      # Render-time checks for a binding that names ANOTHER field: same:
      # (issue #395), after: (#396) and clear: (#394). The binding's attrs are
      # built before its section's children render, so the check waits for the
      # end of the OUTERMOST Phlex render in progress and reads the fields that
      # render produced — a field below the binding, or inside a nested
      # component, counts. An unknown name (or a file input named in clear:)
      # raises ArgumentError at render, never silently in the browser.
      #
      # Nothing is recorded when no binding names a field, and a helper called
      # outside a render (no buffer to read) is not checked. A fragment render
      # (only part of the template reaches the buffer) is not checked either.
      module FieldReferences
        REFS_KEY = :__phlex_reactive_field_refs

        # A start tag and its attributes (quoted values may hold ">").
        TAG = %r{<[a-zA-Z][\w-]*((?:\s+[^\s"'>/=]+(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s"'>]+))?)*)\s*/?>}
        ATTR_NAME = /\sname\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))/
        ATTR_TYPE_FILE = %r{\stype\s*=\s*(?:"file"|'file'|file(?=[\s>/]))}i

        private

        def around_template(&)
          # Thread#[] is fiber-local: a nested component, or a capture inside
          # this render, shares the outermost render's list. `true` marks a
          # render in progress with nothing recorded yet, so a render without
          # such a binding allocates nothing here.
          return super if Thread.current[REFS_KEY] || !defined?(@_state) || @_state.nil?

          buffer = @_state.buffer
          start = buffer.bytesize
          Thread.current[REFS_KEY] = true
          begin
            super
            refs = Thread.current[REFS_KEY]
          ensure
            Thread.current[REFS_KEY] = nil
          end
          check_field_references!(refs, buffer.byteslice(start..)) if refs.is_a?(Array) && !@_state.fragments
        end

        # Record a binding's field references for the end-of-render check.
        # `names` are bare show names (scope-aware, like the client resolver);
        # `no_file` refuses a file input under the name.
        def reference_fields!(helper, key, names, no_file: false)
          refs = Thread.current[REFS_KEY]
          return unless refs

          refs = Thread.current[REFS_KEY] = [] if refs == true
          names.each { refs << [helper, key, it, field_wire_name(it), no_file] }
        end

        # Every same: name in a binding's compiled groups (issue #395).
        def reference_same_fields!(helper, groups)
          names = groups.flatten.filter_map { it["same"] }
          reference_fields!(helper, :same, names.uniq) if names.any?
        end

        # The name the client's resolver queries: scope[name] under
        # reactive_scope, a bracketed name (an author's raw wire name) verbatim.
        def field_wire_name(name)
          name.include?("[") ? name : scoped_field_name(name)
        end

        def check_field_references!(refs, html)
          names, files = rendered_fields(html)
          refs.each do |helper, key, name, wire, no_file|
            unless names.include?(wire)
              raise ArgumentError,
                "#{helper} #{key}: #{name.to_sym.inspect} names no field this render produced " \
                "(no element with name=\"#{wire}\")"
            end
            next unless no_file && files.include?(wire)

            raise ArgumentError,
              "#{helper} #{key}: #{name.to_sym.inspect} is a file input — a file field cannot be cleared"
          end
        end

        # The name of every element the HTML renders, and those that are
        # file inputs.
        def rendered_fields(html)
          names = Set.new
          files = Set.new
          html.scan(TAG) do
            attrs = Regexp.last_match(1).to_s
            next unless (match = ATTR_NAME.match(attrs))

            name = CGI.unescapeHTML(match[1] || match[2] || match[3])
            names << name
            files << name if ATTR_TYPE_FILE.match?(attrs)
          end
          [names, files]
        end
      end
    end
  end
end
