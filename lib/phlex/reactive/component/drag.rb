# frozen_string_literal: true

# DRAG_MESSAGES_JSON is built with Hash#to_json while this file loads.
require "json"

module Phlex
  module Reactive
    module Component
      # Draggable regions (issue #416): a box that moves and resizes inside a
      # frame, or a point that moves inside it, with the result in fields as
      # fractions of the frame — 0..1 on each axis, so a resize, a responsive
      # layout or a morph changes nothing about them.
      #
      #   div(**mix(reactive_frame, class: "relative")) do
      #     img(src: @photo.url, alt: "", class: "block w-full")
      #     div(**reactive_box(fields: { x: "crop[x]", y: "crop[y]", width: "crop[width]", height: "crop[height]" },
      #                        value: @crop.to_h, aspect: "crop[aspect]")) do
      #       %i[nw n ne e se s sw w].each { span(**reactive_box_handle(it)) }
      #       span(**reactive_point(fields: { x: "focus[x]", y: "focus[y]" }, value: @focus.to_h, within: "[data-reactive-box]"))
      #     end
      #   end
      #
      # The box, its handles and the point render their position as inline
      # percentages, so the first paint is right with no JavaScript and a
      # re-render with new values moves them. The frame's padding box is the
      # coordinate space; the frame must be positioned (relative or absolute),
      # which the helper leaves to the author. Style the look with classes, and
      # add any inline style AFTER the helper's: mix(reactive_box(...), style: "…").
      #
      # The client (features/drag.js) drags them with a mouse, a pen or a
      # finger, and the keyboard: arrows move 1% (Shift: 10%), Alt+arrows
      # resize from the bottom-right corner or from the focused handle, Escape
      # puts the drag back, each step announced in the words of `messages:`.
      # The fields get `input` as the box moves and one `change` on release.
      # `action:` is sent once on release through the root's pipeline; without
      # it the binding is client-only and works on a ClientBindings root.
      module Drag
        # The announcement words, {x}, {y}, {width} and {height} filled in by
        # the client as whole percents. Override any of them with messages:.
        DRAG_MESSAGES = {
          moved: "Moved to {x}%, {y}%",
          resized: "Resized to {width}% by {height}%",
          cancelled: "Cancelled"
        }.freeze

        # Where each handle sits on the box (left, top) and the cursor it shows.
        DRAG_HANDLES = {
          nw: ["0%", "0%", "nwse"], n: ["50%", "0%", "ns"], ne: ["100%", "0%", "nesw"], e: ["100%", "50%", "ew"],
          se: ["100%", "100%", "nwse"], s: ["50%", "100%", "ns"], sw: ["0%", "100%", "nesw"], w: ["0%", "50%", "ew"]
        }.freeze

        BOX_KEYS = %i[x y width height].freeze
        POINT_KEYS = %i[x y].freeze
        # A ratio written as a String: "16:9", "1.5".
        RATIO_STRING = /\A\s*\d*\.?\d+\s*(:\s*\d*\.?\d+\s*)?\z/
        # A box may end at the frame's edge as the fields round it: x and width
        # rounded apart to 4 decimals can sum to 1.0001 (0.45545 + 0.54455).
        EDGE_SLACK = 1e-4 + 1e-9

        # The coordinate space: its padding box is 0..1 on each axis.
        def reactive_frame = { data: { reactive_frame: true } }

        # A box that moves and resizes inside the frame.
        #
        #   fields:    { x:, y:, width:, height: } — the names of the fields that hold it
        #   value:     { x:, y:, width:, height: } — where it is, fractions of the frame
        #   aspect:    a Numeric ratio (16/9r), or the name of a field holding one
        #              ("16:9", "1.5", or "" for free), read at drag start
        #   min:       the smallest width/height, a fraction of the frame
        #   action:    sent once on release, with x/y/width/height params
        #   busy:      on(busy:)'s vocabulary, applied while that action is pending
        #   messages:  the live-region words, merged over DRAG_MESSAGES
        def reactive_box(fields:, value:, aspect: nil, min: 0.05, action: nil, busy: nil, messages: nil)
          fields = drag_fields!(:reactive_box, fields, BOX_KEYS)
          value = drag_value!(:reactive_box, value, BOX_KEYS)
          drag_inside_frame!(value)
          data = { reactive_box: fields.to_json, reactive_box_min: drag_min!(min) }
          drag_aspect!(aspect, data) unless aspect.nil?
          drag_action!(:reactive_box, action, busy, data)
          data[:reactive_box_messages] = drag_messages!(:reactive_box, messages)
          style = "position: absolute; box-sizing: border-box; left: #{drag_percent(value[:x])}; " \
                  "top: #{drag_percent(value[:y])}; width: #{drag_percent(value[:width])}; " \
                  "height: #{drag_percent(value[:height])}; touch-action: none; cursor: move;"
          { tabindex: 0, style:, data: }
        end

        # An edge or corner of the box (inside it) to resize from: nw n ne e se s sw w.
        def reactive_box_handle(edge)
          left, top, cursor = DRAG_HANDLES.fetch(edge.to_s.to_sym) do
            raise ArgumentError,
              "reactive_box_handle got an unknown edge #{edge.inspect} — one of " \
              "#{DRAG_HANDLES.keys.map(&:inspect).join(", ")}"
          end
          { tabindex: -1,
            style: "position: absolute; left: #{left}; top: #{top}; translate: -50% -50%; touch-action: none; " \
                   "cursor: #{cursor}-resize;",
            data: { reactive_box_handle: edge.to_s } }
        end

        # A point (its centre) that moves inside the frame — or, with within:,
        # inside the element it sits in that matches the selector (a box): its
        # fractions are then of that element, and it moves with it.
        def reactive_point(fields:, value:, within: nil, action: nil, busy: nil, messages: nil)
          fields = drag_fields!(:reactive_point, fields, POINT_KEYS)
          value = drag_value!(:reactive_point, value, POINT_KEYS)
          data = { reactive_point: fields.to_json }
          data[:reactive_point_within] = drag_within!(within) unless within.nil?
          drag_action!(:reactive_point, action, busy, data)
          data[:reactive_point_messages] = drag_messages!(:reactive_point, messages)
          style = "position: absolute; left: #{drag_percent(value[:x])}; top: #{drag_percent(value[:y])}; " \
                  "translate: -50% -50%; touch-action: none; cursor: move;"
          { tabindex: 0, style:, data: }
        end

        private

        # A fraction as a percentage with at most 2 decimals, rounded as the
        # client rounds (Math.round(v * 1e4) / 100): 0.1 -> "10%".
        def drag_percent(fraction) = "#{((fraction * 10_000).round / 100.0).to_s.delete_suffix(".0")}%"

        def drag_fields!(helper, fields, keys)
          example = "fields: { #{keys.map { "#{it}: \"region[#{it}]\"" }.join(", ")} }"
          raise ArgumentError, "#{helper} fields: must be a Hash, e.g. #{example}" unless fields.is_a?(Hash)

          fields = fields.transform_keys { it.to_s.to_sym }
          drag_keys!(helper, :fields, fields, keys, example)
          fields.each do |key, name|
            next if (name.is_a?(String) || name.is_a?(Symbol)) && !name.to_s.strip.empty?

            raise ArgumentError, "#{helper} fields: #{key} needs a field name, got #{name.inspect}"
          end
          fields.slice(*keys).transform_values(&:to_s)
        end

        def drag_keys!(helper, option, hash, keys, example)
          missing = keys - hash.keys
          unless missing.empty?
            raise ArgumentError,
              "#{helper} #{option}: is missing #{missing.map(&:inspect).join(", ")} — e.g. #{example}"
          end

          unknown = hash.keys - keys
          return if unknown.empty?

          raise ArgumentError,
            "#{helper} got an unknown #{option}: key #{unknown.first.inspect} — it takes #{keys.map(&:inspect).join(", ")}"
        end

        def drag_value!(helper, value, keys)
          raise ArgumentError, "#{helper} value: must be a Hash of fractions, got #{value.inspect}" unless value.is_a?(Hash)

          value = value.transform_keys { it.to_s.to_sym }
          drag_keys!(helper, :value, value, keys, "value: { #{keys.map { "#{it}: 0.5" }.join(", ")} }")
          value.each do |key, number|
            next if number.is_a?(Numeric) && number.real? && number.between?(0, 1)

            raise ArgumentError, "#{helper} value: #{key} must be a number from 0 to 1 (a fraction), got #{number.inspect}"
          end
          value
        end

        def drag_inside_frame!(value)
          %i[width height].each do
            raise ArgumentError, "reactive_box value: #{it} must be greater than 0" unless value[it].positive?
          end
          { x: :width, y: :height }.each do |at, size|
            sum = value[at] + value[size]
            next if sum <= 1 + EDGE_SLACK

            raise ArgumentError,
              "reactive_box value: #{at} + #{size} is #{sum.round(4)} — the box must stay inside the frame (at most 1)"
          end
        end

        def drag_min!(min)
          # (A Float: a Rational would render as "1/10", which the browser cannot read.)
          return min.to_f if min.is_a?(Numeric) && min.real? && min.positive? && min <= 1

          raise ArgumentError,
            "reactive_box min: must be a fraction of the frame above 0 and at most 1 (e.g. 0.05), got #{min.inspect}"
        end

        def drag_aspect!(aspect, data)
          if aspect.is_a?(Numeric) && aspect.real? && aspect.positive? && aspect.finite?
            data[:reactive_box_ratio] = aspect.to_f
          elsif aspect.is_a?(String) && aspect.match?(RATIO_STRING)
            raise ArgumentError,
              "reactive_box aspect: #{aspect.inspect} is a ratio, not a field name — pass 16/9r or 1.5 " \
              "(a Numeric), or the name of a field whose value is \"16:9\""
          elsif (aspect.is_a?(String) || aspect.is_a?(Symbol)) && !aspect.to_s.strip.empty?
            data[:reactive_box_aspect] = aspect.to_s
          else
            raise ArgumentError,
              "reactive_box aspect: must be a positive Numeric (16/9r) or the name of a field holding the ratio, " \
              "got #{aspect.inspect}"
          end
        end

        def drag_within!(within)
          return within if within.is_a?(String) && !within.strip.empty?

          raise ArgumentError,
            "reactive_point within: needs a CSS selector matching the element the point sits inside, " \
            "e.g. \"[data-reactive-box]\", got #{within.inspect}"
        end

        def drag_action!(helper, action, busy, data)
          if action.nil?
            raise ArgumentError, "#{helper} busy: needs an action: — it is applied while that action is pending" if busy

            return
          end

          drag_requires_component!(helper)
          name = drag_action_name!(helper, action)
          data[:"#{helper}_action"] = name
          data[:"#{helper}_busy"] = pending_hint_json(busy, name, :busy) if busy
        end

        def drag_requires_component!(helper)
          return if self.class.include?(Phlex::Reactive::Component::Identity)

          raise ArgumentError,
            "#{helper} action: needs the full Phlex::Reactive::Component — a release calls a server action, " \
            "which Phlex::Reactive::ClientBindings has no token for. Without action: the fields alone hold it."
        end

        # The on() courtesy (issue #105): an undeclared action fails at render
        # under verbose_errors, not as a 403 on release.
        def drag_action_name!(helper, action)
          if action.to_s.strip.empty?
            raise ArgumentError, "#{helper} action: needs the name of a declared action, got #{action.inspect}"
          end

          if Phlex::Reactive.verbose_errors &&
             (actions = self.class.reactive_actions).any? && !actions.key?(action.to_sym)
            raise Phlex::Reactive::Error,
              "#{self.class} has no declared action #{action.to_sym.inspect} (declared: #{actions.keys.inspect})"
          end

          action.to_s
        end

        def drag_messages!(helper, messages)
          return DRAG_MESSAGES_JSON if messages.nil?
          raise ArgumentError, "#{helper} messages: must be a Hash, got #{messages.inspect}" unless messages.is_a?(Hash)

          unknown = messages.keys.map { it.to_s.to_sym } - DRAG_MESSAGES.keys
          unless unknown.empty?
            raise ArgumentError,
              "#{helper} got an unknown messages: key #{unknown.first.inspect} — " \
              "supported: #{DRAG_MESSAGES.keys.map(&:inspect).join(", ")}"
          end

          messages.each do |name, words|
            unless words.is_a?(String)
              raise ArgumentError,
                "#{helper} messages: #{name} must be a String, got #{words.inspect}"
            end
          end

          DRAG_MESSAGES.merge(messages.transform_keys { it.to_s.to_sym }).to_json
        end

        DRAG_MESSAGES_JSON = DRAG_MESSAGES.to_json
        private_constant :DRAG_MESSAGES_JSON, :DRAG_HANDLES, :BOX_KEYS, :POINT_KEYS, :RATIO_STRING, :EDGE_SLACK
      end
    end
  end
end
