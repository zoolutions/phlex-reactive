# frozen_string_literal: true

# A server component whose checkboxes sit partly in its own root and partly
# inside client-only SearchableListComponent roots (issue #410). Every box
# dispatches :pick, and the action receives every ticked box, wherever it is.
class TagPickerComponent < ApplicationComponent
  include Phlex::Reactive::Streamable
  include Phlex::Reactive::Component

  COLOURS = %w[blue green].freeze
  SHAPES = %w[circle square].freeze

  reactive_state :picked
  action :pick, params: { tags: [:string] }

  def initialize(picked: [])
    @picked = picked
  end

  def id = "tag_picker"

  def pick(tags: [])
    @picked = tags
    reply.morph
  end

  def view_template
    div(**reactive_root(data: { testid: "tag-picker" })) do
      p(data: { testid: "picked" }) { "picked:#{@picked.join(",")}" }
      tag_box("red")
      render(SearchableListComponent.new(name: "colours")) { COLOURS.each { tag_box(it) } }
      render(SearchableListComponent.new(name: "shapes")) do
        SHAPES.each { tag_box(it) }
      end
    end
  end

  private

  def tag_box(value)
    label(data: { option: true, testid: "option-#{value}" }) do
      input(**mix(on(:pick, event: "change"), type: "checkbox", name: "tags[]", value:,
        checked: @picked.include?(value), data: { testid: "tag-#{value}" }))
      plain value
    end
  end
end
