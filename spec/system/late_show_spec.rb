# frozen_string_literal: true

require "system_helper"

# A root whose first show target a stream appends (issue #356): the root
# carries no bindings marker and is not re-rendered, so it never asked for the
# bindings feature at connect. After the append the target must be seeded from
# the field and follow it — on both clients.
RSpec.describe "A show target appended by a stream (issue #356)", type: :system do
  def bindings_fetches
    page.evaluate_script(<<~JS)
      performance.getEntriesByType("resource").filter((e) => e.name.includes("/features/bindings.js")).length
    JS
  end

  before { visit "/late_show" }

  it "hides the appended target from the field's value and toggles it with the field" do
    find("[data-testid='add']").click
    expect(page).to have_css("[data-testid='pro-panel']", visible: :hidden)

    find("[data-testid='mode']").select("Pro")
    expect(page).to have_css("[data-testid='pro-panel']", visible: :visible, text: "Pro options")

    find("[data-testid='mode']").select("Basic")
    expect(page).to have_css("[data-testid='pro-panel']", visible: :hidden)
  end

  it "fetches the bindings module once the stream brings the target, not before", :split_client do
    expect(page).to have_css("[data-testid='add']")
    expect(bindings_fetches).to eq(0)
    find("[data-testid='add']").click
    expect(page).to have_css("[data-testid='pro-panel']", visible: :hidden)
    expect(bindings_fetches).to eq(1)
  end
end
