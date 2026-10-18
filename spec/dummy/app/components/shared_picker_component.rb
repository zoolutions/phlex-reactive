# frozen_string_literal: true

# A form widget with an action of its own (issue #434), rendered inside
# SharedFieldFormComponent. Its hidden value field is shared, so the form's
# save posts it; its note field is internal and only its own pick sees it.
# `pick` declares the shared field under the host's name too (item[choice]),
# as its own action posts it: `previous` is what the hidden field held.
class SharedPickerComponent < ApplicationComponent
  include Phlex::Reactive::Streamable
  include Phlex::Reactive::Component

  reactive_state :choice, :previous, :note
  action :pick, params: { choice: :string, item: { choice: :string }, picker_note: :string }

  def initialize(choice: nil, previous: nil, note: nil)
    @choice = choice
    @previous = previous
    @note = note
  end

  def id = "picker"

  def pick(choice: nil, item: {}, picker_note: nil)
    @previous = item[:choice]
    @choice = choice
    @note = picker_note
  end

  def view_template
    div(**reactive_root(data: { testid: "picker" })) do
      input(type: "hidden", **reactive_shared_field(name: "item[choice]", value: @choice))
      input(name: "picker_note", value: "internal", data: { testid: "picker-note" })
      button(**mix(on(:pick, choice: "b"), data: { testid: "picker-pick-b" })) { "Pick b" }
      button(**mix(on(:pick, choice: "c"), data: { testid: "picker-pick-c" })) { "Pick c" }
      span(data: { testid: "picker-state" }) { "choice=#{@choice} previous=#{@previous} note=#{@note}" }
    end
  end
end
