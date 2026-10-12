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

  # Issue #366: delete and backspace are not in Stimulus's default key map. The
  # helper binds a bare window keydown and the client matches the chord, so
  # Stimulus never sees an "unknown key filter" (it would throw at keypress).
  describe "keys Stimulus does not know (issue #366)" do
    before do
      page.execute_script(<<~JS)
        window.__errors = []
        const error = console.error
        console.error = (...args) => { window.__errors.push(args.map(String).join(" ")); error(...args) }
        window.addEventListener("error", (e) => window.__errors.push(String(e.message)))
      JS
    end

    # Stimulus reports an unknown key filter by throwing from its listener.
    def expect_no_page_errors = expect(page.evaluate_script("window.__errors")).to be_empty

    def select_beta
      find("[data-testid='row-beta']").click
      expect(page).to have_css("li[aria-selected='true']", text: "beta")
      reset_reactive_requests!
      # The select re-rendered the root, so its window listeners were re-added
      # after the recorder: record again from a listener added after them.
      page.execute_script(<<~JS)
        window.__preventedAfterSelect = []
        window.addEventListener("keydown", (e) => window.__preventedAfterSelect.push(e.defaultPrevented))
      JS
    end

    def prevented_after_select = page.evaluate_script("window.__preventedAfterSelect")

    it "removes the selected row on Delete, prevented, with one request" do
      select_beta
      find("body").send_keys(:delete)

      expect(page).to have_no_css("[data-testid='row-beta']")
      expect(page).to have_css("[data-testid='row-alpha']")
      expect(page).to have_reactive_requests(1, kind: :action)
      expect(prevented_after_select).to eq([true])
      expect_no_page_errors
    end

    it "leaves Delete typed in the search box to the field" do
      select_beta
      search = find("[data-testid='search']")
      search.fill_in(with: "abc")
      search.send_keys(:home, :delete)

      expect(search.value).to eq("bc")
      expect { expect(page).to have_reactive_requests(1, wait: 0.5) }
        .to raise_error(RSpec::Expectations::ExpectationNotMetError)
      expect(page).to have_css("[data-testid='row-beta']")
      expect_no_page_errors
    end

    it "ignores other keys on the page (not prevented, no request)" do
      select_beta
      find("body").send_keys("x", :backspace)

      expect { expect(page).to have_reactive_requests(1, wait: 0.5) }
        .to raise_error(RSpec::Expectations::ExpectationNotMetError)
      expect(page).to have_css("[data-testid='row-beta']")
      expect(page).to have_css("[data-testid='preview']", visible: :visible)
      expect(prevented_after_select).to eq([false, false])
      expect_no_page_errors
    end

    it "hides the preview on this platform's mod+Backspace only" do
      find("body").send_keys([other_mod, :backspace])
      expect(page).to have_css("[data-testid='preview']", visible: :visible)

      find("body").send_keys([mod, :backspace])
      expect(page).to have_css("[data-testid='preview']", visible: :hidden)
      expect(reactive_request_count).to eq(action: 0, defer: 0)
      expect(prevented).to eq([false, true])
      expect_no_page_errors
    end
  end
end
