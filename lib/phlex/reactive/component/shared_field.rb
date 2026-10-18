# frozen_string_literal: true

module Phlex
  module Reactive
    module Component
      # A field a nested component shares with its host (issue #434). A reactive
      # component rendered inside another is its own root, and its named fields
      # are its own (issue #15). A form widget with actions of its own (a picker
      # that stores the chosen id in a hidden field) still has to post that value
      # with the form around it:
      #
      #   input(type: "hidden", **reactive_shared_field(name: "item[choice]", value: @choice))
      #   # => name="item[choice]" value="…" data-reactive-shared-field
      #
      # The marked control is collected by its own root's actions AND by the
      # next token-bearing root above it (client-only roots in between are
      # transparent, issue #410). One level only: a grand-host collects it only
      # when the host marks a copy of its own. A native <form> posts it anyway,
      # as it does any named control.
      #
      # The name is the HOST's param and goes on the wire verbatim, never
      # re-scoped under this component's reactive_scope.
      module SharedField
        def reactive_shared_field(name:, value: nil, **attrs)
          unless (name.is_a?(String) || name.is_a?(Symbol)) && !name.to_s.strip.empty?
            raise ArgumentError,
              "reactive_shared_field needs a non-blank String or Symbol name: " \
              "(the host's param, e.g. name: \"item[choice]\"), " \
              "got #{name.inspect}"
          end

          binding = { name: name.to_s }
          binding[:value] = value unless value.nil?
          binding[:data] = { reactive_shared_field: true }
          mix(binding, attrs)
        end
      end
    end
  end
end
