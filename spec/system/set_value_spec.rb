# frozen_string_literal: true

require "system_helper"

# Issue #374: js.set_value, end to end in a real browser. A click assigns the
# field's live .value (not the attribute), dispatches ONE bubbling `input`
# when the value changed — so a reactive_show bound to a hidden field reacts
# as if typed — and never dispatches `change` or moves focus. No fetch, ever.
RSpec.describe "Set a field's live value (issue #374 js.set_value)", type: :system do
  # Count every input/change on the textarea and remember where focus was,
  # plus a fetch spy and a reload marker. Installed after the page connects.
  def install_probes
    page.execute_script(<<~JS)
      window.__events = { input: 0, change: 0, bubbledInput: 0 }
      const notes = document.getElementById("notes")
      notes.addEventListener("input", () => window.__events.input++)
      notes.addEventListener("change", () => window.__events.change++)
      document.getElementById("notes-fill").addEventListener("input", (e) => {
        if (e.target === notes) window.__events.bubbledInput++
      })
      window.__fetchCount = 0
      const original = window.fetch
      window.fetch = (...args) => { window.__fetchCount++; return original(...args) }
      window.__marker = "kept"
      window.__warns = []
      const warn = console.warn
      console.warn = (...args) => { window.__warns.push(String(args[0])); warn(...args) }
    JS
  end

  def events = page.evaluate_script("window.__events")

  def notes_value = page.evaluate_script("document.getElementById('notes').value")

  before do
    visit "/notes_fill"
    # The connect barrier: the controller is live before any probe or click.
    find("#notes-fill[data-reactive-connected]")
    install_probes
  end

  it "fills the textarea and the hidden key in one click: one bubbling input, no change, no focus move" do
    find("[data-testid='fill']").click

    expect(page).to have_field("notes", with: "Thanks for your order.")
    # The hidden key's `input` drove the reactive_show, exactly like typing.
    expect(page).to have_css("[data-testid='template-picked']", text: "Template: thanks")
    expect(page.evaluate_script("document.getElementById('template_key').value")).to eq("thanks")
    expect(events).to eq("input" => 1, "change" => 0, "bubbledInput" => 1)
    # Focus stayed on the trigger the user clicked, never jumped to the field.
    expect(page.evaluate_script("document.activeElement?.dataset?.testid")).to eq("fill")
    expect(page.evaluate_script("window.__fetchCount")).to eq(0)
    expect(page.evaluate_script("window.__marker")).to eq("kept")
  end

  it "does not dispatch input again for the same string" do
    find("[data-testid='fill']").click
    expect(page).to have_field("notes", with: "Thanks for your order.")

    find("[data-testid='fill']").click

    expect(events["input"]).to eq(1)
  end

  it "stores an HTML-looking string as those characters" do
    find("[data-testid='html']").click

    expect(page).to have_field("notes", with: "<b>bold</b>")
    expect(page).to have_no_css("#notes b")
  end

  it "clears a non-empty field (nil) and dispatches input" do
    find("[data-testid='notes']").fill_in(with: "draft")
    page.execute_script("window.__events.input = 0")

    find("[data-testid='clear']").click

    expect(page).to have_field("notes", with: "")
    expect(events["input"]).to eq(1)
  end

  it "selects the matching option of a select" do
    expect(page).to have_select("tone", selected: "Formal")

    find("[data-testid='tone']").click

    expect(page).to have_select("tone", selected: "Warm")
  end

  it "refuses a non-empty value for a file input (keeps its files) and clears it with \"\"" do
    file = Tempfile.new(%w[report .txt])
    file.write("x")
    file.close
    find("[data-testid='file']").attach_file(file.path)
    files_count = -> { page.evaluate_script("document.getElementById('file').files.length") }
    expect(files_count.call).to eq(1)

    find("[data-testid='file-bad']").click
    expect(page.evaluate_script("window.__warns")).to include(a_string_including("set_value skipped"))
    expect(files_count.call).to eq(1)

    find("[data-testid='file-clear']").click
    expect(page).to have_field("file", with: "")
    expect(files_count.call).to eq(0)
  ensure
    file&.unlink
  end

  it "skips a contenteditable target (reactive_editable owns it)" do
    find("[data-testid='editable']").click

    expect(page.evaluate_script("window.__warns")).to include(a_string_including("set_value skipped"))
    expect(page).to have_css("[data-testid='body']", exact_text: "Editable")
  end

  it "leaves set_attr(\"value\") an attribute write — the typed live value stays" do
    find("[data-testid='notes']").fill_in(with: "typed")
    page.execute_script("window.__events.input = 0")

    find("[data-testid='attr']").click

    expect(page.evaluate_script("document.getElementById('notes').getAttribute('value')")).to eq("From the attribute")
    expect(notes_value).to eq("typed")
    expect(events["input"]).to eq(0)
  end
end
