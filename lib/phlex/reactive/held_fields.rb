# frozen_string_literal: true

module Phlex
  module Reactive
    # The fields a morph held over a changed server value (issue #370).
    #
    # Since #338 a morph keeps the value of the field being typed in and writes
    # the render's value as the field's default. When that render differs from
    # the old default, someone else changed the field while the user typed.
    # The client marks such a field and the root's next action request names it
    # in the X-Reactive-Held header (a JSON array of field names). Inside the
    # action, `reactive_held_fields` returns those names, so the app can refuse
    # or merge instead of silently overwriting the other change:
    #
    #   def save(title: nil)
    #     authorize!(@note, to: :update?)
    #     return reply.morph.refused("title") if reactive_held_fields.include?("title") && title != @note.title
    #     ...
    #
    # A reply to the root's own request releases its marks: it answers exactly
    # those values. A refusal (`reply.morph.refused`, issue #413) is sent back
    # in the X-Reactive-Refused header, and the client keeps the marks it names,
    # so the user's next keystroke is refused too until the action stores the
    # field or the user takes the other value.
    #
    # The header is UNTRUSTED input, like every request field: it carries names
    # only, never values, and is read as data — capped in bytes, count and
    # length, non-strings dropped, and filtered to the names the running action
    # declares as params (matched on the base name, so `title[en]` counts for a
    # declared `title`). A name the action can't receive can't be overwritten
    # by it. Malformed input reads as nothing held; it never fails a request.
    # It is a hint about what the user saw, not authorization.
    module HeldFields
      HEADER = "X-Reactive-Held"
      # The response header a refusing reply sends (issue #413).
      REFUSED_HEADER = "X-Reactive-Refused"

      # A raw header longer than this is ignored unparsed.
      MAX_BYTES = 4_096
      # At most this many names are read …
      MAX_NAMES = 64
      # … each at most this long.
      MAX_NAME_LENGTH = 128

      EMPTY = [].freeze

      class << self
        # The held field names during the current action ([] outside one).
        def current
          Thread.current[:phlex_reactive_held_fields] || EMPTY
        end

        # Expose `names` for the block, restoring the previous list after.
        def with(names)
          previous = Thread.current[:phlex_reactive_held_fields]
          Thread.current[:phlex_reactive_held_fields] = names
          yield
        ensure
          Thread.current[:phlex_reactive_held_fields] = previous
        end

        # The header's names that `action_def` declares, frozen; [] for
        # anything absent, oversized or malformed.
        def parse(raw, action_def)
          return EMPTY if raw.nil? || raw.empty? || raw.bytesize > MAX_BYTES

          names = JSON.parse(raw)
          names.is_a?(Array) ? filter(names, action_def) : EMPTY
        rescue JSON::ParserError
          EMPTY
        end

        # The X-Reactive-Refused value for Response#refused_fields: "*" keeps
        # every mark, a JSON list keeps those names. ASCII only (a header is a
        # byte string), as the client escapes X-Reactive-Held. A list past
        # MAX_BYTES (a header a proxy may refuse) widens to "*": keeping more
        # marks than named is safe, losing the refusal is not.
        def refused_header(fields)
          return "*" if fields == :all

          json = JSON.generate(fields, ascii_only: true)
          json.bytesize > MAX_BYTES ? "*" : json
        end

        # Keep the strings among `names` that `action_def` declares as params.
        def filter(names, action_def)
          declared = declared_names(action_def)
          return EMPTY if declared.empty?

          names.first(MAX_NAMES).select do
            it.is_a?(String) && it.length <= MAX_NAME_LENGTH && declared.include?(base_name(it))
          end.uniq.freeze
        end

        private

        def declared_names(action_def)
          params = action_def.params
          params.is_a?(Hash) ? params.keys.map(&:to_s) : EMPTY
        end

        # "title" for "title", "title[]" and "title[en]".
        def base_name(name) = name.split("[", 2).first
      end
    end
  end
end
