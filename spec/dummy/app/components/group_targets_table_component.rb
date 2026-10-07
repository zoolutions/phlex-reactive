# frozen_string_literal: true

# Issue #343: a checkbox list that is its OWN reactive root (its narrow action
# re-renders it by morph), driving a bulk bar the page renders OUTSIDE it —
# the counts and the buttons through reactive_group_targets, the bar's
# visibility through reactive_show_targets.
class GroupTargetsTableComponent < ApplicationComponent
  include Phlex::Reactive::Component

  skip_verify_authorized

  ITEMS = { 1 => "First item", 2 => "Second item", 3 => "Third item" }.freeze

  reactive_state :narrowed, :emptied
  action :narrow
  action :empty

  def initialize(narrowed: false, emptied: false)
    @narrowed = narrowed
    @emptied = emptied
  end

  def id = "items-table"

  def reactive_values = { "ids[]" => [] }

  # Drops the first row: a reply that changes the rows.
  def narrow
    @narrowed = true
    reply.morph
  end

  # Drops every row (#348): the root then owns no box of the group.
  def empty
    @emptied = true
    reply.morph
  end

  def view_template
    div(**mix(
      reactive_root,
      reactive_show_targets("#bulk-bar" => { if: { "ids[]" => { checked: 1.. } } }),
      reactive_group_targets("ids[]",
        count: ["#bulk-count", "#footer-count"],
        enable: { "#bulk-archive" => 1.., "#bulk-merge" => 2 })
    )) do
      input(type: "checkbox", **reactive_select_all("ids[]", data: { testid: "all" }))
      ul(id: "item-rows") { items.each { |id, title| row(id, title) } }
      button(**mix(on(:narrow), data: { testid: "narrow" })) { "Narrow" }
      button(**mix(on(:empty), data: { testid: "empty" })) { "Empty" }
    end
  end

  private

  def items
    return {} if @emptied

    @narrowed ? ITEMS.except(1) : ITEMS
  end

  def row(id, title)
    li(id: "item-#{id}") do
      label do
        input(type: "checkbox", name: "ids[]", value: id, form: "bulk", data: { testid: "row-#{id}" })
        plain " #{title}"
      end
    end
  end
end
