# frozen_string_literal: true

# Issue #346: a bulk-action form whose successful reply only swaps #flash (the
# rows stay), so the selection is cleared client-side — on a SUCCESSFUL submit
# only. on_client("turbo:submit-end", …, detail: { success: true }) skips a
# failed (422) submit, which keeps the ticked boxes for the retry.
class BulkOutcomeComponent < ApplicationComponent
  include Phlex::Reactive::ClientBindings

  POSTS = { 1 => "First post", 2 => "Second post", 3 => "Third post" }.freeze

  def reactive_values = { "ids[]" => [] }

  def view_template
    div(id: "bulk-outcome", **reactive_root) do
      form(id: "bulk-outcome-form", action: "/bulk_outcome", method: "post",
        **on_client("turbo:submit-end", js.check_group("ids[]", false), detail: { success: true })) do
        label do
          input(type: "checkbox", **reactive_select_all("ids[]", data: { testid: "all" }))
          plain " Select all"
        end
        POSTS.each do |id, title|
          label do
            input(type: "checkbox", name: "ids[]", value: id, data: { testid: "row-#{id}" })
            plain " #{title}"
          end
        end
        p do
          plain "Selected: "
          span(**reactive_count("ids[]", data: { testid: "count" })) { "0" }
        end
        button(name: "op", value: "publish", data: { testid: "publish" }) { "Publish" }
        button(name: "op", value: "fail", data: { testid: "fail" }) { "Publish (fails)" }
      end
    end
  end
end
