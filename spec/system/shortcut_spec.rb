# frozen_string_literal: true

require "system_helper"

# Issue #357: shortcut: on on() / on_client(). The three reproduction steps of
# the issue, in a real browser: the chord inside the textarea is the
# browser's (no request, not prevented), the chord on the page dispatches once
# and is prevented, and only this platform's `mod` twin fires.
RSpec.describe "Page-level keyboard shortcuts (issue #357)", type: :system do
  before do
    visit "/shortcuts"
    find("[data-reactive-connected]")
    # Runs after Stimulus's window listener (added at connect): it sees
    # whether the reactive binding prevented the chord. The modifier keys'
    # own keydowns are left out.
    page.execute_script(<<~JS)
      window.__prevented = []
      window.addEventListener("keydown", (e) => {
        if (!["Meta", "Control", "Shift", "Alt"].includes(e.key)) window.__prevented.push(e.defaultPrevented)
      })
    JS
    reset_reactive_requests!
  end

  # The client resolves `mod` from the platform the browser reports.
  let(:apple) { page.evaluate_script("/[Mm]ac|iP/.test(navigator.userAgentData?.platform ?? navigator.platform)") }
  let(:mod) { apple ? :meta : :control }
  let(:other_mod) { apple ? :control : :meta }

  def prevented = page.evaluate_script("window.__prevented")

  it "dispatches undo once from the page and prevents the chord" do
    find("[data-testid='list']").click
    find("body").send_keys([mod, "z"])

    expect(page).to have_css("[data-testid='undos']", text: "1")
    expect(page).to have_reactive_requests(1, kind: :action)
    expect(prevented).to eq([true])
  end

  it "keeps the chord inside the textarea for the browser: no request, not prevented" do
    notes = find("[data-testid='notes']")
    notes.click
    notes.send_keys("hello")
    notes.send_keys([mod, "z"])

    expect { expect(page).to have_reactive_requests(1, wait: 0.5) }
      .to raise_error(RSpec::Expectations::ExpectationNotMetError)
    expect(page).to have_css("[data-testid='undos']", exact_text: "0")
    expect(prevented.last).to be(false)
  end

  it "ignores the other platform's twin" do
    find("[data-testid='list']").click
    find("body").send_keys([other_mod, "z"])

    expect { expect(page).to have_reactive_requests(1, wait: 0.5) }
      .to raise_error(RSpec::Expectations::ExpectationNotMetError)
    expect(page).to have_css("[data-testid='undos']", exact_text: "0")
    expect(prevented).to eq([false])
  end

  it "tells undo from redo by the shift modifier" do
    find("body").send_keys([mod, :shift, "z"])

    expect(page).to have_css("[data-testid='redos']", text: "1")
    expect(page).to have_css("[data-testid='undos']", exact_text: "0")
  end

  it "runs an on_client shortcut's ops without a request" do
    find("body").send_keys([mod, "k"])

    expect(page).to have_css("[data-testid='palette']", visible: :visible)
    expect(reactive_request_count).to eq(action: 0, defer: 0)
    expect(prevented).to eq([true])
  end
end
