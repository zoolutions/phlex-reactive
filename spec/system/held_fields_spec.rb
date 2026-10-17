# frozen_string_literal: true

require "system_helper"

# Issue #370: the issue's reproduction. Tab B types in the title; another tab
# saves a different title and its broadcast morphs B's form. B keeps its text
# (#338) — and now the field is marked data-reactive-held, a reactive:held
# event reports the server's value, and B's next debounced save carries
# X-Reactive-Held: ["title"], so the action refuses to overwrite A's title.
# The refusal keeps the mark (issue #413), so B's next keystroke is refused
# too, even after another broadcast re-rendered the form.
#
# The other tab's broadcast is delivered by hand (the dummy's Action Cable runs
# the test adapter): the same morph stream broadcast_to(..., morph: true) sends.
#
# Runs under Puma (sync) AND Falcon (async) in CI's server matrix.
RSpec.describe "Knowing what a morph held (issue #370)", type: :system do
  let(:todo) { Todo.create!(title: "Original") }

  def broadcast_from_other_tab(title)
    todo.update!(title:)
    html = HeldNoteComponent.new(todo: todo.reload).to_stream_replace(morph: true).to_s
    page.execute_script("Turbo.renderStreamMessage(arguments[0])", html)
  end

  it "tells B's save that its title was held over A's change, so it can refuse the overwrite" do
    visit "/held_note/#{todo.id}"
    page.execute_script(<<~JS)
      window.__held = []
      document.addEventListener("reactive:held", (event) => window.__held.push(event.detail))
    JS

    title = find("[data-testid='title']")
    title.click
    title.send_keys(" draft")
    expect(page).to have_css("[data-testid='saved']", exact_text: "Original draft")
    # B's own reply marked nothing.
    expect(page).to have_no_css("[data-reactive-held]")

    broadcast_from_other_tab("Final by A")

    expect(page).to have_css("[data-testid='saved']", exact_text: "Final by A")
    expect(page).to have_field("title", with: "Original draft")
    expect(page).to have_css("[data-testid='title'][data-reactive-held]")
    expect(page.evaluate_script("window.__held")).to eq([{ "name" => "title", "theirs" => "Final by A" }])

    title.send_keys(" more")

    expect(page).to have_css("[data-testid='conflict']",
      text: "Someone changed the title to Final by A while you typed Original draft more")
    expect(page).to have_css("[data-testid='held']", exact_text: "title")
    expect(todo.reload.title).to eq("Final by A")
    # The refusal kept the mark (issue #413) …
    expect(page).to have_css("[data-testid='title'][data-reactive-held]")

    # … through a broadcast that lands while the refusal shows (the field is
    # still focused) …
    broadcast_from_other_tab("Final by A, again")
    expect(page).to have_css("[data-testid='saved']", exact_text: "Final by A, again")
    expect(page).to have_no_css("[data-testid='conflict']")
    expect(page).to have_css("[data-testid='title'][data-reactive-held]")

    # … so B's next keystroke is refused too, instead of saving over A's title.
    title.send_keys("!")

    expect(page).to have_css("[data-testid='conflict']",
      text: "Someone changed the title to Final by A, again while you typed Original draft more!")
    expect(todo.reload.title).to eq("Final by A, again")
    expect(page).to have_css("[data-testid='title'][data-reactive-held]")
  end

  it "releases the mark once the user takes the other value and the save stores it" do
    visit "/held_note/#{todo.id}"

    title = find("[data-testid='title']")
    title.click
    title.send_keys(" draft")
    expect(page).to have_css("[data-testid='saved']", exact_text: "Original draft")
    broadcast_from_other_tab("Final by A")
    expect(page).to have_css("[data-testid='title'][data-reactive-held]")

    title.send_keys(:backspace)
    title.fill_in(with: "Final by A")

    expect(page).to have_no_css("[data-reactive-held]")
    expect(page).to have_no_css("[data-testid='conflict']")
    expect(todo.reload.title).to eq("Final by A")
  end

  it "marks nothing when the morph renders the value the field already had as its default" do
    visit "/held_note/#{todo.id}"

    title = find("[data-testid='title']")
    title.click
    title.send_keys(" draft")
    expect(page).to have_css("[data-testid='saved']", exact_text: "Original draft")

    broadcast_from_other_tab("Original draft")

    expect(page).to have_field("title", with: "Original draft")
    expect(page).to have_no_css("[data-reactive-held]")
  end
end
