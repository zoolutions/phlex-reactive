# frozen_string_literal: true

# Exercises checkbox GROUPS (issue #258): three boxes sharing one `features[]`
# name, a lone yes/no box, and a <select multiple>. Before the fix the client
# collected each checkbox as a boolean under its own name, so the group left the
# browser as a single `false` — the last box's checked state — whatever the
# schema declared. `save` declares the group as an array of strings and reflects
# the COERCED result as JSON, so a request spec can assert the exact structure
# and a system spec can drive the same component through a real browser.
class CheckboxGroupComponent < ApplicationComponent
  include Phlex::Reactive::Streamable
  include Phlex::Reactive::Component

  FEATURES = %w[news events maps].freeze
  REGIONS = %w[north south].freeze
  # The two the page renders ticked, so a system spec has something to untick.
  CHECKED_FEATURES = %w[news events].freeze

  reactive_state :received

  action :save, params: { features: [:string], subscribe: :boolean, regions: [:string], attachment: :file }
  # A group declared one level down, so the announcement's bound can be checked
  # against a name the endpoint does NOT resolve.
  action :save_scoped, params: { project: { features: [:string] } }
  # Written with STRING keys on purpose: ParamSchema.compile keeps the keys it is
  # given, so the announcement's schema lookup has to read both forms.
  action :save_string_keys, params: { "features" => [:string] }

  def initialize(received: nil)
    @received = received
  end

  def id = "checkbox-group"

  def save(features: nil, subscribe: nil, regions: nil, attachment: nil)
    @received = { features:, subscribe:, regions:, attachment: attachment&.original_filename }
  end

  def save_scoped(project: nil)
    @received = { project: }
  end

  def save_string_keys(features: nil)
    @received = { features: }
  end

  def view_template
    div(id:, **reactive_attrs) do
      FEATURES.each do
        # Bound before the nested block: inside `label do … end`, `it` would
        # refer to THAT block's parameter, not to the feature being rendered.
        feature = it
        label do
          input(type: "checkbox", name: "features[]", value: feature,
            checked: CHECKED_FEATURES.include?(feature),
            data: { testid: "feature-#{feature}" })
          plain(feature)
        end
      end

      label do
        input(type: "checkbox", name: "subscribe", value: "yes", checked: true,
          data: { testid: "subscribe" })
        plain("subscribe")
      end

      select(name: "regions[]", multiple: true, data: { testid: "regions" }) do
        REGIONS.each do
          region = it
          option(value: region, selected: region == "north") { region }
        end
      end

      # A file input so a system spec can drive the FORM-encoded path, where the
      # announcement lives — with no file the client sends JSON.
      input(type: "file", name: "attachment", data: { testid: "attachment" })

      button(**mix(on(:save), data: { testid: "save" })) { "Save" }

      # The exact coerced structure, types intact, for the assertions.
      pre(data: { testid: "received" }) { @received.to_json }
    end
  end
end
