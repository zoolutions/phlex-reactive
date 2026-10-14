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
      module ShowOptions
        private

        # The wire data for a reactive_show's options, merged into its data:.
        def show_option_data(groups, after:)
          data = {}
          data[:reactive_show_after] = show_after_field!(groups, after) unless after.nil?
          data
        end

        def show_after_field!(groups, after)
          fields = Phlex::Reactive::ShowConditions.fields(groups)
          unless after.is_a?(Symbol) || after.is_a?(String)
            raise ArgumentError,
              "reactive_show after: takes :blur or the name of the condition's field to wait for, got #{after.inspect}"
          end

          name = after.to_s == "blur" ? show_after_single!(fields) : after.to_s
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
