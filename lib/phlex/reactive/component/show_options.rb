# frozen_string_literal: true

module Phlex
  module Reactive
    module Component
      # The reactive_show keywords beyond the condition itself.
      #
      # after: (issue #396) — keep the section hidden until the named field has
      # fired `blur` once since connect. `after: :blur` names the condition's
      # one field; a condition over several fields names it: `after: :code`.
      # The client keeps the touched flag on the root's controller, so a morph
      # keeps it and a full navigation (a new controller) drops it. The server
      # cannot have seen a blur, so first paint is hidden.
      #
      # clear:, focus:, scroll: (issue #394) — work the client does when the
      # section CHANGES visibility, never on first paint. Going hidden, each
      # clear: field (owned, scope-aware) is emptied with js.set_value's write
      # (a checkbox or radio is unchecked; a file input is rejected at render) and a bubbling
      # `input` is dispatched per field that changed. Going visible, the first
      # element inside the root matching focus: is focused, and scroll: true
      # scrolls the section into view. clear: names are checked at render: an
      # unknown one, or a file input, raises.
      module ShowOptions
        private

        # The wire data for a reactive_show's options, merged into its data:.
        def show_option_data(groups, after:, clear:, focus:, scroll:)
          data = {}
          data[:reactive_show_after] = show_after_field!(groups, after) unless after.nil?
          data[:reactive_show_clear] = show_clear_fields!(clear).to_json unless clear.nil?
          data[:reactive_show_focus] = show_focus!(focus) unless focus.nil?
          data[:reactive_show_scroll] = "true" if show_scroll!(scroll)
          data
        end

        def show_clear_fields!(clear)
          names = Array(clear).map do
            name = it.to_s if it.is_a?(Symbol) || it.is_a?(String)
            next name unless name.nil? || name.strip.empty?

            raise ArgumentError,
              "reactive_show clear: takes a field name or an Array of them, got #{clear.inspect}"
          end
          raise ArgumentError, "reactive_show clear: needs at least one field name, got #{clear.inspect}" if names.empty?

          reference_fields!(:reactive_show, :clear, names.uniq, no_file: true)
          names.uniq
        end

        def show_focus!(focus)
          return focus if focus.is_a?(String) && !focus.strip.empty?

          raise ArgumentError,
            "reactive_show focus: takes a non-empty CSS selector inside the root (e.g. \"#notes\"), got #{focus.inspect}"
        end

        def show_scroll!(scroll)
          return scroll if [nil, true, false].include?(scroll)

          raise ArgumentError, "reactive_show scroll: takes true or false, got #{scroll.inspect}"
        end

        def show_after_field!(groups, after)
          fields = Phlex::Reactive::ShowConditions.fields(groups)
          unless after.is_a?(Symbol) || after.is_a?(String)
            raise ArgumentError,
              "reactive_show after: takes :blur or the name of the condition's field to wait for, got #{after.inspect}"
          end

          name = after == :blur ? show_after_single!(fields) : after.to_s
          unless fields.include?(name)
            raise ArgumentError,
              "reactive_show after: #{after.inspect} is not a field of this condition " \
              "(it names #{fields.map(&:to_sym).inspect})"
          end

          reference_fields!(:reactive_show, :after, [name])
          name
        end

        def show_after_single!(fields)
          return fields.first if fields.size == 1

          raise ArgumentError,
            "reactive_show after: :blur needs a condition over one field — this one names " \
            "#{fields.map(&:to_sym).inspect}; pass the field to wait for (after: #{fields.first.to_sym.inspect})"
        end
      end
    end
  end
end
