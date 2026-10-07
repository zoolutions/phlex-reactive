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

        # CROSS-ROOT group bindings (issue #343) — the count and enable
        # sibling of reactive_show_targets. The group bindings above only see
        # boxes this root owns (#15), so a list that is its own reactive root
        # cannot drive a bulk bar the page renders outside it. The root that
        # OWNS the boxes declares the outside ids it drives instead. Spread it
        # on the ROOT (mix alongside reactive_root and reactive_show_targets):
        #
        #   div(**mix(reactive_root,
        #     reactive_show_targets("#bulk-bar" => { if: { "ids[]" => { checked: 1.. } } }),
        #     reactive_group_targets("ids[]",
        #       count:  "#bulk-count",                  # textContent = ticked count
        #       enable: { "#bulk-archive" => 1.. })))   # disabled = !(count in range)
        #
        # Targets are SINGLE ID SELECTORS (raised here, warn-skipped by the
        # client) resolved document-wide; a missing one is skipped. An enable
        # value is an Integer (an exact count), a Range (a threshold) or a full
        # if:/if_any:/unless: conditions Hash. They re-sync with the in-root
        # bindings: every change, a morph, rows added or removed.
        #
        # ONE call per root (mix space-joins a second call's JSON into an
        # unparseable attr); several groups go in the hash form:
        #
        #   reactive_group_targets("ids[]" => { count: "#c" }, "tags[]" => { enable: { "#t" => 1.. } })
        #
        # The outside markup gets its first paint from reactive_group_target_attrs.
        def reactive_group_targets(group = nil, **options)
          if group.nil? && (options.key?(:count) || options.key?(:enable))
            raise ArgumentError, "reactive_group_targets needs the group first: " \
                                 "reactive_group_targets(\"ids[]\", #{options.keys.map { "#{it}: ..." }.join(", ")})"
          end

          groups =
            if group.nil? then options
            elsif group.is_a?(Hash) then group
            else { group => options }
            end
          if groups.empty?
            raise ArgumentError, "reactive_group_targets needs a group and its targets: " \
                                 "reactive_group_targets(\"ids[]\", count: \"#id\", enable: { \"#id\" => 1.. })"
          end

          wire = groups.to_h do |name, targets|
            name = selection_group!(:reactive_group_targets, name)
            [name, normalize_group_targets(name, targets)]
          end
          { data: { reactive_group_targets: wire.to_json } }
        end

        # First paint for an element a reactive_group_targets root drives but
        # another component renders (computed from THIS component's
        # reactive_values, so the outside markup never flashes):
        #
        #   span(id: "bulk-count") { reactive_group_target_attrs("ids[]", :count).to_s }   # the ticked count
        #   button(id: "bulk-archive", **reactive_group_target_attrs("ids[]", :enable, 1..)) # { disabled: }
        #
        # :count is the Integer (0 for an empty or absent group). :enable is
        # { disabled: true|false }, or {} when reactive_values does not cover
        # the group (the client seeds it at connect).
        def reactive_group_target_attrs(group, kind, condition = nil)
          name = selection_group!(:reactive_group_target_attrs, group)
          case kind
          when :count then Phlex::Reactive::ShowConditions.checked_count(show_values(nil)&.dig(name))
          when :enable
            match = first_paint_match(group_enable_payload(name, "reactive_group_target_attrs", condition)["any"], nil)
            match.nil? ? {} : { disabled: !match }
          else
            raise ArgumentError, "reactive_group_target_attrs takes :count or :enable, got #{kind.inspect}"
          end
        end

        private

        def normalize_group_targets(name, targets)
          unless targets.is_a?(Hash) && (targets.key?(:count) || targets.key?(:enable))
            raise ArgumentError, "reactive_group_targets(#{name.inspect}) needs count: or enable:, got #{targets.inspect}"
          end
          if (unknown = targets.keys - %i[count enable]).any?
            raise ArgumentError, "reactive_group_targets(#{name.inspect}): unknown option(s) " \
                                 "#{unknown.map(&:inspect).join(", ")} — it takes count: and enable:"
          end

          wire = {}
          wire["count"] = Array(targets[:count]).map { group_target_selector!(name, it) } if targets.key?(:count)
          if targets.key?(:enable)
            wire["enable"] = targets[:enable].to_h do |selector, condition|
              [group_target_selector!(name, selector), group_enable_payload(name, "reactive_group_targets", condition)]
            end
          end
          wire
        end

        def group_target_selector!(name, selector)
          selector = selector.to_s
          return selector if selector.match?(DSL::MIRROR_ID_SELECTOR)

          raise ArgumentError, "reactive_group_targets(#{name.inspect}) target #{selector.inspect} must be a single " \
                               "ID selector (\"#id\") — cross-root targets are id-allowlisted, like reactive_show_targets"
        end

        # An enable condition as the { "any" => groups } DNF payload: an
        # Integer or Range is the group's checked count, a Hash is the full
        # reactive_show conditions language.
        def group_enable_payload(name, helper, condition)
          conditions =
            case condition
            when Integer, Range then { if: { name => { checked: condition } } }
            when Hash
              if (unknown = condition.keys - Helpers::SHOW_CONDITION_KEYS).any?
                raise ArgumentError, "#{helper}(#{name.inspect}): unknown conditions key(s) " \
                                     "#{unknown.map(&:inspect).join(", ")} — it takes if:/if_any:/unless:"
              end
              condition
            else
              raise ArgumentError, "#{helper}(#{name.inspect}) enable takes an Integer (exact count), a Range " \
                                   "(threshold) or an if:/if_any:/unless: conditions Hash, got #{condition.inspect}"
            end
          { "any" => Phlex::Reactive::ShowConditions.normalize(**conditions) }
        end

        def selection_group!(helper, group)
          name = group.to_s
          return name unless name.strip.empty?

          raise ArgumentError, "#{helper} needs a checkbox group name (e.g. \"ids[]\"), got #{group.inspect}"
        end
      end
    end
  end
end
