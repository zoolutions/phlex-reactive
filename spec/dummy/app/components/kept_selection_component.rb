# frozen_string_literal: true

# Issue #369: keep: on client ops. A live list whose selection lives on the
# client: clicking an item selects it (a class, aria-selected, its details
# panel shown) with kept ops, and marks it "touched" with an op WITHOUT keep:.
# A morph of the list — what broadcast_to(…, morph: true) sends — keeps the
# kept state and drops the rest. `renamed:` changes one item's server render
# (its name and a class) so the spec can tell the render still lands.
class KeptSelectionComponent < ApplicationComponent
  include Phlex::Reactive::Component

  ITEMS = { 1 => "Alpha", 2 => "Bravo", 3 => "Charlie" }.freeze

  def initialize(renamed: nil)
    @renamed = renamed
  end

  def id = "kept-list"

  def view_template
    div(**reactive_root) do
      ITEMS.each { |n, name| item(n, name) }
    end
  end

  private

  def item(n, name)
    renamed = n == @renamed
    div(**mix(on_client(:click, select(n)), id: "item-#{n}", class: ["item", ("renamed" if renamed)],
      aria_selected: "false", data: { testid: "item-#{n}" })) do
      span(data: { testid: "name-#{n}" }) { renamed ? "#{name} (renamed)" : name }
      div(id: "details-#{n}", class: "details", hidden: true, data: { testid: "details-#{n}" }) { "Details of #{name}" }
    end
  end

  def select(n)
    js.remove_class(".item", "selected", keep: true)
      .set_attr(".item", "aria-selected", "false", keep: true)
      .hide(".details", keep: true)
      .add_class("#item-#{n}", "selected", keep: true)
      .set_attr("#item-#{n}", "aria-selected", "true", keep: true)
      .show("#details-#{n}", keep: true)
      .add_class("#item-#{n}", "touched")
  end
end
