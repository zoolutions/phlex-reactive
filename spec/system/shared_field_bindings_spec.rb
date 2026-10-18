# frozen_string_literal: true

require "system_helper"

# Issue #440: a client-only picker keeps its chosen value in a required named
# field inside its own root, marked with reactive_shared_field. The form around
# it reads that field in its client bindings: a reactive_show(disable: true)
# group around the picker disables it while hidden (so it never blocks a native
# submit), and a show, a reactive_enable and a compute mirror follow the pick.
RSpec.describe "A shared field drives its host's client bindings (issue #440)", type: :system do
  let(:form_valid) { "document.querySelector(\"[data-testid='native-form']\").checkValidity()" }

  before do
    visit "/shared_bindings"
    page.execute_script("window.__noReload = 'alive'")
  end

  it "disables the picker's required field while its group is hidden, so a native submit goes through" do
    page.execute_script(<<~JS)
      window.__submits = 0
      document.querySelector("[data-testid='native-form']").addEventListener("submit", (event) => {
        event.preventDefault()
        window.__submits++
      })
    JS

    expect(page).to have_css("[data-testid='picker-group']", visible: :hidden)
    expect(page).to have_css("[data-testid='picker-choice'][disabled]", visible: :hidden)
    # The picker's own query field is unmarked: the host's group leaves it be.
    expect(page).to have_css("[data-testid='picker-q']:not([disabled])", visible: :hidden)
    expect(page.evaluate_script(form_valid)).to be(true)
    find("[data-testid='native-submit']").click
    expect(page.evaluate_script("window.__submits")).to eq(1)

    find("[data-testid='mode']").select("other")
    expect(page).to have_css("[data-testid='picker-choice']:not([disabled])")
    # Shown and empty, the required field blocks the native submit again.
    expect(page.evaluate_script(form_valid)).to be(false)
    find("[data-testid='native-submit']").click
    expect(page.evaluate_script("window.__submits")).to eq(1)

    find("[data-testid='mode']").select("a")
    expect(page).to have_css("[data-testid='picker-choice'][disabled]", visible: :hidden)
    expect(page.evaluate_script("window.__noReload")).to eq("alive")
  end

  it "a nested server picker replaced by its own action while hidden comes back disabled" do
    shared = "#picker input[name='item[choice]']"
    expect(page).to have_css("#{shared}[disabled]", visible: :hidden)

    # The group is hidden, so its button is clicked from script; the action's
    # reply is a plain replace, which renders the shared field enabled.
    page.execute_script("document.querySelector(\"[data-testid='picker-pick-b']\").click()")
    expect(page).to have_css("#{shared}[value='b'][disabled]", visible: :hidden)
    expect(page.evaluate_script(form_valid)).to be(true)
    expect(page.evaluate_script("window.__noReload")).to eq("alive")
  end

  it "a pick drives the host's show, enable and compute mirror, and the save posts it" do
    find("[data-testid='mode']").select("other")
    expect(page).to have_css("[data-testid='save'][disabled]")
    expect(page).to have_css("[data-testid='b-picked']", visible: :hidden)

    find("[data-testid='picker-option-b']").click
    expect(page).to have_css("[data-testid='b-picked']", text: "b picked")
    expect(page).to have_css("[data-testid='save']:not([disabled])")
    expect(page).to have_css("[data-testid='choice-echo']", text: "b")

    find("[data-testid='picker-option-c']").click
    expect(page).to have_css("[data-testid='b-picked']", visible: :hidden)
    expect(page).to have_css("[data-testid='save'][disabled]")
    expect(page).to have_css("[data-testid='choice-echo']", text: "c")

    find("[data-testid='picker-option-b']").click
    find("[data-testid='save']").click
    expect(page).to have_css("[data-testid='saved']", text: "choice=b mode=other")
    expect(page.evaluate_script("window.__noReload")).to eq("alive")
  end
end
