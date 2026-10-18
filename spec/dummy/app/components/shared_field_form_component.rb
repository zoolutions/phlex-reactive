# frozen_string_literal: true

# An item form that saves through a reactive action and holds a picker widget
# (its own reactive component) whose value it must post (issue #434). `save`
# also declares the widget's internal `picker_note`, to show that it does NOT
# arrive: only the shared field crosses into the form's params.
class SharedFieldFormComponent < ApplicationComponent
  include Phlex::Reactive::Streamable
  include Phlex::Reactive::Component

  reactive_state :title, :choice, :saved
  action :save, params: { item: { title: :string, choice: :string }, picker_note: :string }

  def initialize(title: nil, choice: nil, saved: nil)
    @title = title
    @choice = choice
    @saved = saved
  end

  def id = "item-form"

  def save(item: {}, picker_note: nil)
    @title = item[:title]
    @choice = item[:choice]
    @saved = "title=#{@title} choice=#{@choice} note=#{picker_note}"
  end

  def view_template
    div(**reactive_root(data: { testid: "item-form" })) do
      input(name: "item[title]", value: @title, data: { testid: "item-title" })
      render SharedPickerComponent.new(choice: @choice)
      button(**mix(on(:save), data: { testid: "item-save" })) { "Save" }
      span(data: { testid: "item-saved" }) { @saved.to_s }
    end
  end
end
