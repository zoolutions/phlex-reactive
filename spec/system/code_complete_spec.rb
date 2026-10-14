# frozen_string_literal: true

require "system_helper"

# Issue #226: the DECLARATIVE completion binding, end to end — a
# reactive_on_complete with ZERO JavaScript. The Ruby-declared length:
# condition (the ShowConditions #226 form) is evaluated by the generic client
# on every input; the rising edge runs js.dispatch("code:complete"), which the
# root's own on(:verify, event: "code:complete") turns into ONE signed action
# POST. Length-exact semantics prove the re-arm: a 7th character makes the
# condition FALSE, so trimming back to six fires again.
RSpec.describe "Declarative code completion (issue #226 reactive_on_complete)", type: :system do
  def install_post_counter
    page.execute_script(<<~JS)
      window.__actionPosts = 0
      const orig = window.fetch
      window.fetch = (url, opts) => {
        if (String(url).includes("/reactive/actions")) window.__actionPosts++
        return orig(url, opts)
      }
      window.__marker = "kept"
    JS
  end

  it "fires the declared ops exactly once when the condition first becomes true" do
    visit "/code_complete"
    expect(page).to have_css("[data-testid='status']", text: "waiting")
    install_post_counter

    find("[data-testid='code']").set("12345") # incomplete — nothing fires
    expect(page).to have_field("code", with: "12345")
    expect(page.evaluate_script("window.__actionPosts")).to eq(0)

    find("[data-testid='code']").set("123456")

    expect(page).to have_css("[data-testid='status']", text: "verified:123456")
    expect(page.evaluate_script("window.__actionPosts")).to eq(1)
    expect(page.evaluate_script("window.__marker")).to eq("kept") # no reload
  end

  it "re-arms when the condition goes false and fires again at exactly six" do
    visit "/code_complete"
    install_post_counter

    find("[data-testid='code']").set("111111")
    expect(page).to have_css("[data-testid='status']", text: "verified:111111")
    expect(page.evaluate_script("window.__actionPosts")).to eq(1)

    # The post-verify render arms without firing; seven characters make the
    # len_eq 6 condition FALSE — no fire, and the latch re-arms. Append ONE key:
    # the driver's set() types character by character, and typing "1234567"
    # into the field passes through six characters, which fires (rightly).
    find("[data-testid='code']").send_keys(:end, "7")
    expect(page).to have_field("code", with: "1111117")
    expect(page.evaluate_script("window.__actionPosts")).to eq(1)

    # Back to exactly six → the rising edge fires once more.
    find("[data-testid='code']").set("654321")
    expect(page).to have_css("[data-testid='status']", text: "verified:654321")
    expect(page.evaluate_script("window.__actionPosts")).to eq(2)
  end
end
