# frozen_string_literal: true

require "system_helper"

# A root whose first editable a stream appends (issue #351): the root carries no
# bindings marker and is not re-rendered, so it never asked for the bindings
# feature at connect. Focusing the editable must still give it Enter/Escape.
RSpec.describe "Editable text appended by a stream (issue #351)", type: :system do
  let(:late) { find("[data-testid='late-title']") }

  def bindings_fetches
    page.evaluate_script(<<~JS)
      performance.getEntriesByType("resource").filter((e) => e.name.includes("/features/bindings.js")).length
    JS
  end

  before { visit "/late_editable" }

  it "swallows Enter and reverts on Escape in an editable a stream appended" do
    find("[data-testid='add']").click
    late.click
    late.send_keys(" more")
    late.send_keys(:enter)
    expect(page.evaluate_script("document.querySelector(\"[data-testid='late-title']\").innerHTML")).to eq("Draft more")

    late.send_keys(:escape)
    expect(page).to have_css("[data-testid='late-title']", exact_text: "Draft")
  end

  it "fetches the bindings module once the stream brings the editable, not before", :split_client do
    expect(page).to have_css("[data-testid='add']")
    expect(bindings_fetches).to eq(0)
    find("[data-testid='add']").click
    expect(page).to have_css("[data-testid='late-title']")
    expect(bindings_fetches).to eq(1)
  end
end
