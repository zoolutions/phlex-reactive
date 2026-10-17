# frozen_string_literal: true

module Phlex
  module Reactive
    module Component
      # Fields that feed CSS custom properties on an element (issue #417): a
      # preview that follows a control, with no request.
      #
      #   div(**mix(reactive_root(id: "light"), reactive_css_vars(to: "#sample", vars: {
      #     "--light" => "light",                       # field name -> custom property
      #     "--turn"  => { field: "turn", unit: "deg" } # with a unit from UNITS
      #   }))) do
      #     input(type: "range", name: "light", min: "0.5", max: "1.5", step: "0.01", value: "1")
      #     img(id: "sample", alt: "", style: "--light: 1; filter: brightness(var(--light, 1))")
      #   end
      #
      # The client reads each field the way reactive_show does (owned fields, a
      # radio group's checked value, reactive_scope applied; a checkbox gives 1
      # or 0), parses it as a finite number and writes
      # style.setProperty(name, number + unit) on every `to:` element. Anything
      # else (empty, text, NaN) removes the property, so the author's var()
      # fallback applies. No string from a field ever reaches CSS: the wire
      # carries names and units, never a value. It runs on connect, on the
      # fields' input/change, and after a morph. First paint is the author's:
      # render the same properties inline.
      #
      # `to:` resolves like a client op's: inside the root (nested roots
      # excluded), `:root` for the root itself, document-wide with
      # `global: true`; an Array names several. The attribute goes on the root
      # or on any element inside it; `to:` is resolved from the root either way.
      # Client-only: no token, no round trip, no broadcast.
      module CssVarsBinding
        NAME = /\A--[a-z0-9-]+\z/i
        UNITS = ["", "px", "%", "deg", "turn", "ms", "s", "em", "rem", "fr"].freeze

        def reactive_css_vars(to:, vars:, global: false, **attrs)
          wire = { "to" => css_vars_targets!(to), "vars" => css_vars_map!(vars) }
          wire["global"] = true if global
          mix({ data: { reactive_css_vars: wire.to_json } }, attrs)
        end

        private

        def css_vars_targets!(to)
          targets = Array(to)
          if targets.empty? || targets.any? { !it.equal?(:root) && (!it.is_a?(String) || it.strip.empty?) }
            raise ArgumentError, "reactive_css_vars to: takes :root, a CSS selector String (e.g. \"#sample\") " \
                                 "or an Array of them, got #{to.inspect}"
          end

          targets.map { JS.normalize_target(it) }
        end

        def css_vars_map!(vars)
          unless vars.is_a?(Hash) && !vars.empty?
            raise ArgumentError, "reactive_css_vars vars: takes a non-empty Hash of custom property => field " \
                                 "(e.g. vars: { \"--light\" => \"light\" }), got #{vars.inspect}"
          end

          vars.each_with_object({}) do |(name, spec), map|
            name = css_var_name!(name)
            raise ArgumentError, "reactive_css_vars vars: names #{name} twice" if map.key?(name)

            map[name] = css_var_spec!(name, spec)
          end
        end

        def css_var_name!(name)
          string = name.to_s if name.is_a?(String) || name.is_a?(Symbol)
          return string if string&.match?(NAME)

          raise ArgumentError, "reactive_css_vars vars: #{name.inspect} is not a custom property name: it starts " \
                               "with -- and holds only letters, digits and dashes (e.g. \"--light\")"
        end

        def css_var_spec!(name, spec)
          return { "field" => css_var_field!(name, spec) } unless spec.is_a?(Hash)

          unknown = spec.keys - %i[field unit]
          unless unknown.empty?
            raise ArgumentError, "reactive_css_vars vars: #{name} takes only field: and unit:, got #{unknown.inspect}"
          end

          wire = { "field" => css_var_field!(name, spec.fetch(:field, nil)) }
          unit = css_var_unit!(name, spec.fetch(:unit, ""))
          wire["unit"] = unit unless unit.empty?
          wire
        end

        def css_var_field!(name, field)
          string = field.to_s if field.is_a?(String) || field.is_a?(Symbol)
          return string unless string.nil? || string.strip.empty?

          raise ArgumentError, "reactive_css_vars vars: #{name} needs the field name to read " \
                               "(e.g. \"#{name}\" => \"light\" or { field: \"light\", unit: \"px\" }), got #{field.inspect}"
        end

        def css_var_unit!(name, unit)
          string = unit.to_s if unit.is_a?(String) || unit.is_a?(Symbol)
          return string if UNITS.include?(string)

          raise ArgumentError, "reactive_css_vars vars: #{name} unit: must be one of " \
                               "#{UNITS.map(&:inspect).join(", ")}, got #{unit.inspect}"
        end
      end
    end
  end
end
