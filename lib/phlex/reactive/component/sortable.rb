# frozen_string_literal: true

module Phlex
  module Reactive
    module Component
      # Sortable lists (issue #350): drag rows to reorder a list, or drag a row
      # in from another list, and ONE declared action receives the row and its
      # new position — through the normal action pipeline (the signed token,
      # the request queue, busy:, the reply).
      #
      #   ul(**mix(reactive_root, reactive_sortable(:move, handle: "[data-drag-handle]"))) do
      #     @list.tasks.each do |task|
      #       li(id: dom_id(task), **reactive_sortable_item(task.id)) do
      #         span(data: { drag_handle: true }) { "⠿" }
      #         plain task.title
      #       end
      #     end
      #   end
      #
      # On drop the client sends the action with these params (declare the
      # ones you want; default-deny drops the rest):
      #
      #   item      the dragged row's key (reactive_sortable_item(key))
      #   position  its 0-based index in the target list after the drop
      #   after     the key of the row it now follows, nil when it is first
      #   from      "self" for a reorder, else the name of the list it came from
      #
      # The row moves in the DOM at once and moves back when the action fails
      # (or its reply does not render the list). Rows can be dragged with a
      # mouse, a pen or a finger (a 200 ms press), and with the keyboard: a
      # focused row picks up on Space/Enter, moves with the arrow keys, drops
      # on Space/Enter and goes back on Escape, each step announced through a
      # live region in the words of `messages:`.
      #
      # The drag itself is the client's sortable feature module
      # (features/sortable.js); a page without a sortable loads none of it on
      # the split client.
      module Sortable
        # The announcement words, {position} and {count} filled in by the
        # client. Override any of them (a translation) with messages:.
        SORTABLE_MESSAGES = {
          picked: "Picked up item {position} of {count}",
          moved: "Moved to position {position} of {count}",
          dropped: "Dropped",
          cancelled: "Cancelled"
        }.freeze

        # The params the client fills in on drop: a static params: may not set them.
        SORTABLE_DROP_PARAMS = %i[item position after from].freeze

        # A sortable list. `action` is called on drop.
        #
        #   group:     links lists (drag between them) and sources to targets
        #   handle:    a CSS selector, resolved inside each row; only it starts a
        #              pointer drag. Without it the whole row drags.
        #   name:      what a row dragged OUT of this list into another reports
        #              as `from` (and what that list's from: map keys on)
        #   from:      a drag-in calls another action: from: { "templates" => :insert }
        #   params:    static params sent with every drop (e.g. the lane a list is)
        #   disabled:  refuse every drag from or into this list
        #   busy:      on(busy:)'s vocabulary, applied to the list while pending
        #   messages:  the live-region words, merged over SORTABLE_MESSAGES
        def reactive_sortable(action, group: nil, handle: nil, name: nil, from: nil, params: nil,
                              disabled: false, busy: nil, messages: nil)
          sortable_requires_component!
          action = sortable_action!(action)
          data = { reactive_sortable: action }
          data[:reactive_sortable_group] = sortable_name!(:group, group) unless group.nil?
          data[:reactive_sortable_handle] = sortable_handle!(handle) unless handle.nil?
          data[:reactive_sortable_name] = sortable_list_name!(name) unless name.nil?
          data[:reactive_sortable_from] = sortable_from!(from) unless from.nil?
          data[:reactive_sortable_params] = sortable_params!(params) unless params.nil?
          data[:reactive_sortable_disabled] = "true" if disabled
          data[:reactive_sortable_busy] = pending_hint_json(busy, action, :busy) if busy
          data[:reactive_sortable_messages] = sortable_messages!(messages)
          { data: }
        end

        # A list whose rows are COPIED into any sortable of the same group,
        # never moved. The target's action (or its from: mapping for `name`)
        # decides what lands, and its reply renders the new row. Needs no
        # token: it works on a ClientBindings root.
        def reactive_sortable_source(group:, name: "source")
          { data: { reactive_sortable_source: sortable_list_name!(name),
                    reactive_sortable_group: sortable_name!(:group, group) } }
        end

        # A row and its key — a String or an Integer, sent as-is (JSON-typed).
        # The row is focusable, for the keyboard model (unless disabled).
        def reactive_sortable_item(key, disabled: false)
          unless (key.is_a?(String) && !key.strip.empty?) || key.is_a?(Integer)
            raise ArgumentError,
              "reactive_sortable_item key must be a String or an Integer (the row's id), got #{key.inspect}"
          end

          data = { reactive_sortable_item: key.to_json }
          # A disabled row cannot be picked up, so it stays out of the tab order.
          return { data: data.merge(reactive_sortable_disabled: "true") } if disabled

          { tabindex: 0, data: }
        end

        private

        def sortable_requires_component!
          return if self.class.include?(Phlex::Reactive::Component::Identity)

          raise ArgumentError,
            "reactive_sortable needs the full Phlex::Reactive::Component — a drop calls a server action, " \
            "which Phlex::Reactive::ClientBindings has no token for. A copy-only list on a client-only " \
            "root is reactive_sortable_source(group:)."
        end

        # The on() courtesy (issue #105): an undeclared action fails at render
        # under verbose_errors, not as a 403 at drop time.
        def sortable_action!(action)
          if action.nil? || action.to_s.strip.empty?
            raise ArgumentError, "reactive_sortable needs an action to call on drop, e.g. reactive_sortable(:move)"
          end

          if Phlex::Reactive.verbose_errors &&
             (actions = self.class.reactive_actions).any? && !actions.key?(action.to_sym)
            raise Phlex::Reactive::Error,
              "#{self.class} has no declared action #{action.to_sym.inspect} (declared: #{actions.keys.inspect})"
          end

          action.to_s
        end

        def sortable_name!(option, value)
          unless (value.is_a?(String) || value.is_a?(Symbol)) && !value.to_s.strip.empty?
            raise ArgumentError, "reactive_sortable #{option}: needs a name (a String or Symbol), got #{value.inspect}"
          end

          value.to_s
        end

        # "self" is what a reorder within one list reports as `from`.
        def sortable_list_name!(value)
          name = sortable_name!(:name, value)
          if name == "self"
            raise ArgumentError,
              'reactive_sortable name: "self" is reserved — it is the `from` of a reorder within one list'
          end

          name
        end

        def sortable_handle!(handle)
          selector = handle.to_s
          if handle == true || handle == false || selector.strip.empty?
            raise ArgumentError,
              "reactive_sortable handle: needs a CSS selector resolved inside each row " \
              "(e.g. \"[data-drag-handle]\"), got #{handle.inspect}"
          end

          selector
        end

        def sortable_from!(from)
          valid = from.is_a?(Hash) && from.any? && from.keys.all? { !it.to_s.strip.empty? }
          unless valid
            raise ArgumentError,
              "reactive_sortable from: maps a source list's name to the action a drag-in from it calls, " \
              "e.g. from: { \"templates\" => :insert }, got #{from.inspect}"
          end

          from.to_h { |list, action| [sortable_list_name!(list), sortable_action!(action)] }.to_json
        end

        def sortable_params!(params)
          raise ArgumentError, "reactive_sortable params: must be a Hash, got #{params.inspect}" unless params.is_a?(Hash)

          taken = params.keys.map(&:to_sym) & SORTABLE_DROP_PARAMS
          unless taken.empty?
            raise ArgumentError,
              "reactive_sortable params: cannot set #{taken.first.inspect} — the client fills in " \
              "#{SORTABLE_DROP_PARAMS.map(&:inspect).join(", ")} on drop"
          end

          params.to_json
        end

        def sortable_messages!(messages)
          return SORTABLE_MESSAGES_JSON if messages.nil?

          unknown = messages.keys.map(&:to_sym) - SORTABLE_MESSAGES.keys
          unless unknown.empty?
            raise ArgumentError,
              "reactive_sortable got an unknown messages: key #{unknown.first.inspect} — " \
              "supported: #{SORTABLE_MESSAGES.keys.map(&:inspect).join(", ")}"
          end

          SORTABLE_MESSAGES.merge(messages.transform_keys(&:to_sym)).to_json
        end

        SORTABLE_MESSAGES_JSON = SORTABLE_MESSAGES.to_json
        private_constant :SORTABLE_MESSAGES_JSON, :SORTABLE_DROP_PARAMS
      end
    end
  end
end
