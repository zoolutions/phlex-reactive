# frozen_string_literal: true

require "system_helper"

# End-to-end proof that reactive_compute reads and writes CHECKED STATE (issue
# #262), against real DOM semantics — the hidden companion Rails renders before a
# checkbox, a valueless box whose .value is "on", a radio group.
#
# Before #262 the reducer got a constant for every one of them (the companion's
# "0", NaN→0, the first radio's value), so ticking a box recomputed from the same
# values and changed nothing; an output wrote `.value` on the companion.
#
# `readings` prints "<typeof>:<value>" for gift (untyped), express (:boolean) and
# shipping (:string) exactly as the reducer received them.
RSpec.describe "reactive_compute with checkbox and radio controls (issue #262)", type: :system do
  def box(testid) = find("[data-testid='#{testid}']", visible: :all)

  before do
    visit "/compute_checked"
    page.execute_script(<<~JS)
      window.__actionPosts = 0
      const orig = window.fetch
      window.fetch = (url, opts) => {
        if (String(url).includes("/reactive/actions")) window.__actionPosts++
        return orig(url, opts)
      }
    JS
  end

  it "seeds from the rendered checked state on connect" do
    # price 100 + the pre-checked "post" radio (10); both boxes unticked.
    expect(page).to have_field("total", with: "110")
    expect(page).to have_css("[data-testid='readings']", text: "number:0 boolean:false string:post")
  end

  it "reads a ticked Rails checkbox pair as 1, past its hidden companion" do
    box("gift").check

    expect(page).to have_field("total", with: "135")
    expect(page).to have_css("[data-testid='readings']", text: "number:1 boolean:false string:post")

    box("gift").uncheck

    expect(page).to have_field("total", with: "110")
  end

  it "reads a valueless checkbox as a boolean under :boolean" do
    box("express").check

    expect(page).to have_field("total", with: "160")
    expect(page).to have_css("[data-testid='readings']", text: "number:0 boolean:true string:post")
  end

  it "reads the CHECKED radio of a group, not the first one" do
    box("shipping-courier").choose

    expect(page).to have_field("total", with: "130")
    expect(page).to have_css("[data-testid='readings']", text: "string:courier")

    box("shipping-pickup").choose

    expect(page).to have_field("total", with: "100")
  end

  it "writes a checkbox and a radio output as checked state, values untouched" do
    expect(box("free-shipping")).not_to be_checked
    expect(box("tier-basic")).to be_checked # seeded by the connect-time pass

    box("gift").check
    box("express").check
    box("shipping-courier").choose # 100 + 25 + 50 + 30 = 205

    expect(page).to have_field("total", with: "205")
    expect(box("free-shipping")).to be_checked
    expect(box("tier-plus")).to be_checked
    expect(box("tier-basic")).not_to be_checked

    # What each control SUBMITS is unchanged: the write never touched a value.
    expect(box("free-shipping").value).to eq("1")
    expect(box("free-shipping-off").value).to eq("0")
    expect(box("tier-plus").value).to eq("plus")

    box("gift").uncheck # 180 — back under the threshold

    expect(page).to have_field("total", with: "180")
    expect(box("free-shipping")).not_to be_checked
    expect(box("tier-basic")).to be_checked
  end

  it "stays client-side: no reactive round trip" do
    box("gift").check
    expect(page).to have_field("total", with: "135")

    expect(page.evaluate_script("window.__actionPosts")).to eq(0)
  end
end
