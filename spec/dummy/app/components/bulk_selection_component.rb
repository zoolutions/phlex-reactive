# frozen_string_literal: true

# Issue #319: a bulk-selection list with no per-list JavaScript — a header box
# (reactive_select_all), a ticked count (reactive_count), a Delete button and an
# actions fieldset that stay disabled until a box is ticked (reactive_enable
# with the checked: term), and a Delete that confirms, then submits THIS form
# through the hidden submitter (js.submit(…, submitter:)) so the POST carries
# bulk_action=delete. A nested reactive root's box sits inside the outer root:
# it is never counted or flipped. Rows appended or removed by a Turbo stream
# re-sync the header and the count.
class BulkSelectionComponent < ApplicationComponent
  include Phlex::Reactive::ClientBindings

  POSTS = { 1 => "First post", 2 => "Second post", 3 => "Third post" }.freeze

  def initialize(result: nil)
    @result = result
  end

  # First paint: nothing is ticked, so the enables render disabled.
  def reactive_values = { "ids[]" => [] }

  def view_template
    p(data: { testid: "result" }) { @result.to_s }
    div(id: "bulk-root", **reactive_root) do
      form(id: "bulk", action: "/bulk_selection", method: "post") do
        label do
          input(type: "checkbox", **reactive_select_all("ids[]", data: { testid: "all" }))
          plain " Select all"
        end
        ul(id: "rows") { POSTS.each { |id, title| row(id, title) } }
        p do
          plain "Selected: "
          span(**reactive_count("ids[]", data: { testid: "count" })) { "0" }
        end
        fieldset(**reactive_enable(if: { "ids[]" => { checked: 1.. } }, data: { testid: "actions" })) do
          input(type: "text", name: "note", data: { testid: "note" })
        end
        button(
          type: "button",
          **mix(
            reactive_enable(if: { "ids[]" => { checked: 1.. } }),
            on_client(:click, js.submit("#bulk", submitter: "#delete-submit"), confirm: "Delete the selected posts?"),
            data: { testid: "delete" }
          )
        ) { "Delete" }
        button(type: "submit", name: "bulk_action", value: "delete", hidden: true, id: "delete-submit")
      end
      div(data: { controller: "reactive" }) do
        input(type: "checkbox", name: "ids[]", value: "99", data: { testid: "nested" })
      end
    end
  end

  private

  def row(id, title)
    li(id: "row-#{id}") do
      label do
        input(type: "checkbox", name: "ids[]", value: id, data: { testid: "row-#{id}" })
        plain " #{title}"
      end
    end
  end
end
