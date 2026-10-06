# frozen_string_literal: true

module Phlex
  module Reactive
    module Component
      # Bulk-selection bindings (issue #319): a list with a row checkbox per
      # item, a "select all" header, a "Delete (n)" count, and actions that stay
      # disabled until something is ticked — with no per-list JavaScript.
      #
      #   form(id: "bulk", action: "/posts/bulk", method: "post") do
      #     input(type: "checkbox", **reactive_select_all("ids[]"))   # header
      #     @posts.each { input(type: "checkbox", name: "ids[]", value: it.id) }
      #     span(**reactive_count("ids[]")) { "0" }                    # ticked count
      #     button(**reactive_enable(if: { "ids[]" => { checked: 1.. } })) { "Delete" }
      #   end
      #
      # The group is a checkbox NAME, resolved like any reactive_show field
      # (owned boxes only — a nested reactive root's boxes are its own, #15;
      # a bare name takes reactive_scope, a bracketed one like "ids[]" is used
      # verbatim). The client re-syncs the header, the count and every
      # binding when a box changes and when boxes are added or removed (a
      # stream append, a morph, a removal). All client-only: no token, no
      # round trip.
      module Selection
        # The sibling of reactive_show: the same if:/if_any:/unless: conditions
        # (including the { checked: n } count term), but it flips the
        # element's OWN `disabled` — a button, a fieldset — instead of
        # `hidden`. First paint is computed from reactive_values exactly like
        # reactive_show's `hidden:` (an explicit `disabled:` wins; `values:`
        # merges over reactive_values).
        def reactive_enable(**options)
          conditions = options.slice(*Helpers::SHOW_CONDITION_KEYS)
          values_override = options.delete(:values)
          attrs = options.except(*Helpers::SHOW_CONDITION_KEYS)

          groups = Phlex::Reactive::ShowConditions.normalize(**conditions)
          result = mix({ data: { reactive_enable: { "any" => groups }.to_json } }, attrs)
          return result if result.key?(:disabled)

          match = first_paint_match(groups, values_override)
          match.nil? ? result : result.merge(disabled: !match)
        end

        # The header box of a checkbox group. Its `change` ticks or unticks
        # every owned box of the group (dispatching `input` + `change` on each one it
        # flips, so computes, shows and counts re-run); its own checked /
        # indeterminate state follows the group. Give the header NO `name` —
        # it would post, and count as a member.
        def reactive_select_all(group, **attrs)
          mix({ data: { reactive_select_all: selection_group!(:reactive_select_all, group) } }, attrs)
        end

        # A text binding that shows how many owned boxes of the group are
        # ticked (written via textContent, change-guarded). Seed the first
        # paint in the element's own content: span(**reactive_count("ids[]")) { "0" }.
        def reactive_count(group, **attrs)
          mix({ data: { reactive_count: selection_group!(:reactive_count, group) } }, attrs)
        end

        private

        def selection_group!(helper, group)
          name = group.to_s
          return name unless name.strip.empty?

          raise ArgumentError, "#{helper} needs a checkbox group name (e.g. \"ids[]\"), got #{group.inspect}"
        end
      end
    end
  end
end
