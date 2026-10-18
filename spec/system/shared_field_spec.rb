# frozen_string_literal: true

require "system_helper"

# Issue #434: a picker widget is its own reactive component (its own action,
# its own fields) rendered inside an item form that saves through a reactive
# action. Its hidden value field is marked with reactive_shared_field, so the
# form's save posts it too; the widget's internal field stays the widget's.
RSpec.describe "A field a nested component shares with its host (issue #434)", type: :system do
  it "posts the picked value with the form's save, and keeps the widget's own field" do
    visit "/shared_field"
    page.execute_script("window.__noReload = 'alive'")

    find("[data-testid='picker-pick']").click
    # The widget's own action received its own fields.
    expect(page).to have_css("[data-testid='picker-state']", text: "choice=b note=internal")

    find("[data-testid='item-title']").set("Lamp")
    find("[data-testid='item-save']").click

    # The form's save received the shared field, and not the widget's own note.
    expect(page).to have_css("[data-testid='item-saved']", text: "title=Lamp choice=b note=")
    expect(page.evaluate_script("window.__noReload")).to eq("alive")
  end
end
