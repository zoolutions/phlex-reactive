# frozen_string_literal: true

require "system_helper"

# Issue #471: js.click calls HTMLElement#click() on the first match, so the
# browser runs the element's own activation: a link follows its href (through
# Turbo Drive) and a submit button submits its form. window.__marker proves the
# visit was Drive's, not a full reload.
RSpec.describe "js.click (issue #471)", type: :system do
  before do
    visit "/click_op"
    page.find("#click-op[data-reactive-connected]")
    page.execute_script("window.__marker = 'kept'")
  end

  it "follows a link on Space through a Turbo Drive visit, with Space's default prevented" do
    # A document listener runs after the link's own binding: it reads whether
    # Space's default (the page scroll) was prevented.
    page.execute_script(<<~JS)
      document.addEventListener("keydown", (e) => { if (e.key === " ") window.__spacePrevented = e.defaultPrevented })
      document.getElementById("co-link").focus()
    JS
    find("[data-testid='link']").send_keys(:space)

    expect(page).to have_css("[data-testid='arrived']", text: "link")
    expect(page.evaluate_script("window.__spacePrevented")).to be(true)
    expect(page).to have_current_path("/click_op?arrived=link")
    expect(page.evaluate_script("window.__marker")).to eq("kept")
  end

  it "submits a form through its submit button" do
    find("[data-testid='proxy']").click

    expect(page).to have_css("[data-testid='arrived']", text: "form")
    expect(page).to have_current_path("/click_op?arrived=form")
    expect(page.evaluate_script("window.__marker")).to eq("kept")
  end

  it "activates a link under an ancestor click binding with prevent: false" do
    find("[data-testid='wrapped-proxy']").click

    expect(page).to have_css("[data-testid='arrived']", text: "wrapped")
    expect(page).to have_current_path("/click_op?arrived=wrapped")
    expect(page.evaluate_script("window.__marker")).to eq("kept")
  end
end
