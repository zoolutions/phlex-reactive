# frozen_string_literal: true

# Issue #343: the page around GroupTargetsTableComponent. The bulk bar sits in
# the page's own root, outside the table's; a footer count sits outside every
# reactive root. First paint comes from reactive_group_target_attrs.
class GroupTargetsPageComponent < ApplicationComponent
  include Phlex::Reactive::ClientBindings

  def reactive_values = { "ids[]" => [] }

  def view_template
    div(**reactive_root(id: "items-page")) do
      form(id: "bulk", action: "/group_targets", method: "post")
      render GroupTargetsTableComponent.new
      bulk_bar
    end
    p do
      plain "Footer: "
      span(id: "footer-count", data: { testid: "footer-count" }) { reactive_group_target_attrs("ids[]", :count).to_s }
    end
  end

  private

  def bulk_bar
    div(id: "bulk-bar", hidden: true, data: { testid: "bar" }) do
      span(id: "bulk-count", data: { testid: "count" }) { reactive_group_target_attrs("ids[]", :count).to_s }
      plain " selected "
      button(id: "bulk-archive", type: "button", data: { testid: "archive" },
        **reactive_group_target_attrs("ids[]", :enable, 1..)) { "Archive" }
      button(id: "bulk-merge", type: "button", data: { testid: "merge" },
        **reactive_group_target_attrs("ids[]", :enable, 2)) { "Merge two" }
    end
  end
end
