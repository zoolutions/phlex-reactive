# frozen_string_literal: true

require "system_helper"

# Issue #338: reply.morph kept focus and caret (#28) but not the focused field's
# VALUE — Turbo's stream morph runs Idiomorph without ignoreActiveValue, so a
# save whose render differs from the box (normalised, or stale because the user
# kept typing) overwrote it: "Hello " saved as "Hello", then "world" typed after
# it gave "Helloworld". The runtime now holds the focused field's value while
# still writing its fresh default; unfocused fields in the same morph take the
# server's value.
#
# Runs under Puma (sync) AND Falcon (async) in CI's server matrix.
RSpec.describe "Morph keeps the focused field's value (issue #338)", type: :system do
  it "keeps what the user typed in the focused input across a normalising save" do
    visit "/morph_normalize"
    page.execute_script("window.__noReload = 'alive'")

    name = find("[data-testid='name']")
    name.click
    name.send_keys("Hello ")

    # The debounced save landed: the server stripped the space and the morph
    # wrote the unfocused slug from the saved name.
    expect(page).to have_css("[data-testid='saved_name']", exact_text: "Hello")
    expect(page).to have_field("slug", with: "hello")

    # The focused field still holds the trailing space; its default advanced.
    expect(page).to have_field("name", with: "Hello ")
    expect(page.evaluate_script("document.querySelector(\"[data-testid='name']\").defaultValue")).to eq("Hello")
    expect(page.evaluate_script("document.activeElement.dataset.testid")).to eq("name")

    name.send_keys("world")

    expect(page).to have_css("[data-testid='saved_name']", exact_text: "Hello world")
    expect(page).to have_field("slug", with: "hello-world")
    expect(page).to have_field("name", with: "Hello world")
    expect(page.evaluate_script("window.__noReload")).to eq("alive")
  end

  it "keeps what the user typed in the focused textarea across a normalising save" do
    visit "/morph_normalize"

    body = find("[data-testid='body']")
    body.click
    body.send_keys("Line one ")

    expect(page).to have_css("[data-testid='saved_body']", exact_text: "Line one")
    expect(page).to have_field("body", with: "Line one ")

    body.send_keys("more")

    expect(page).to have_css("[data-testid='saved_body']", exact_text: "Line one more")
    expect(page).to have_field("body", with: "Line one more")
  end
end
