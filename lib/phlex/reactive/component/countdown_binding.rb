# frozen_string_literal: true

module Phlex
  module Reactive
    module Component
      # A server deadline counted down on the client (issue #400).
      #
      #   span(**reactive_countdown(until: deadline.iso8601, waiting: "#wait", done: "#done")) { "2:00" }
      #   div(id: "wait") { "Waiting" }
      #   div(id: "done", hidden: true) { "Finished" }
      #
      # The client paints the time left from until: and Date.now at connect and
      # once a second ("1:30": unpadded minutes, a colon, padded seconds — the
      # only format, :ms), as textContent only. A tab that wakes late jumps to
      # the real time left. At zero, or with until: already past on connect, the
      # text is "0:00", data-reactive-countdown-state is "done", waiting: hides,
      # done: shows (CSS selectors inside the root) and the element dispatches
      # reactive:countdown-done once; the timer stops. A morph that keeps until:
      # does not dispatch again; one that changes it counts down again. No
      # request and no frame reload: the event is the hook.
      #
      # The server renders the initial text and visibility, so the page reads
      # with JavaScript off. until: is an ISO8601 date-time WITH a zone (Z or an
      # offset), or a Time, which is written as one: a zoneless string would
      # read as the browser's local time.
      module CountdownBinding
        ISO8601_WITH_ZONE = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})\z/

        # `until` is a keyword: the value is read off the binding.
        def reactive_countdown(until:, format: :ms, waiting: nil, done: nil, **attrs)
          wire = { "until" => countdown_until!(binding.local_variable_get(:until)), "format" => countdown_format!(format) }
          wire["waiting"] = countdown_selector!(:waiting, waiting) unless waiting.nil?
          wire["done"] = countdown_selector!(:done, done) unless done.nil?
          mix({ data: { reactive_countdown: wire.to_json } }, attrs)
        end

        private

        def countdown_until!(value)
          value = value.utc.iso8601(value.subsec.zero? ? 0 : 3) if value.is_a?(Time) || value.respond_to?(:time_zone)
          return value if countdown_iso8601?(value)

          raise ArgumentError, "reactive_countdown until: must be an ISO8601 date-time with a zone " \
                               "(e.g. \"2026-10-14T12:02:00Z\") or a Time, got #{value.inspect}"
        end

        # The shape (a zone is required), then a real date (no month 13).
        def countdown_iso8601?(value)
          value.is_a?(String) && value.match?(ISO8601_WITH_ZONE) && Time.iso8601(value) && true
        rescue ::ArgumentError
          false
        end

        def countdown_format!(format)
          return "ms" if format == :ms

          raise ArgumentError, "reactive_countdown format: must be :ms (the only format), got #{format.inspect}"
        end

        # A selector the client passes to querySelector inside the root.
        def countdown_selector!(name, selector)
          if selector == JS::ROOT_SENTINEL
            raise ArgumentError,
              "reactive_countdown #{name}: #{selector} names the whole root — pass the selector of a node inside it"
          end
          return selector if selector.is_a?(String) && !selector.strip.empty?

          raise ArgumentError,
            "reactive_countdown #{name}: must be a CSS selector (e.g. \"##{name}\"), got #{selector.inspect}"
        end
      end
    end
  end
end
