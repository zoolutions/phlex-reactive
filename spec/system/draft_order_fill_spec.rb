# frozen_string_literal: true

require "system_helper"

# End-to-end proof of fill-then-add (issue #208 Scenario A):
#
#   * The add controls live OUTSIDE the row. Filling them and clicking "Add"
#     SNAPSHOTS their values into a new row (seeded, not typed into), CLEARS the
#     sources, and keeps focus on the sources for the next entry.
#   * It stays pure CLIENT-SIDE form state — a fetch spy proves ZERO action
#     POSTs, a window marker proves no reload.
#   * It composes with BOTH wire modes: accepts_nested_attributes_for (/orders)
#     AND JSON mode (/orders_json). The real submit reconciles the seeded rows.
RSpec.describe "Draft order form — fill-then-add", type: :system do
  def install_fetch_spy
    page.execute_script(<<~JS)
      window.__actionPosts = 0
      const orig = window.fetch
      window.fetch = (url, opts) => {
        if (String(url).includes("/reactive/actions")) window.__actionPosts++
        return orig(url, opts)
      }
      window.__noReload = "alive"
    JS
  end

  it "snapshots the OUTSIDE controls into rows, clears them, and persists via nested attributes" do
    visit "/draft_order_fill"
    expect(page).to have_css("[data-testid='add-item']")
    install_fetch_spy

    # Fill the sources OUTSIDE the row, then Add.
    find("[data-testid='src-qty']").set(3)
    find("[data-testid='src-price']").set(42)
    find("[data-testid='add-item']").click

    # A row appeared, SEEDED from the sources (not typed into the row).
    expect(page).to have_css("[data-testid='item-row']", count: 1)
    row = page.first("[data-testid='item-row']")
    expect(row).to have_field(with: "3")
    expect(row).to have_field(with: "42")

    # The sources were CLEARED for the next entry.
    expect(page).to have_field("src-qty", with: "")
    expect(page).to have_field("src-price", with: "")

    # Add a second item the same way.
    find("[data-testid='src-qty']").set(1)
    find("[data-testid='src-price']").set(9)
    find("[data-testid='add-item']").click
    expect(page).to have_css("[data-testid='item-row']", count: 2)

    # Pure client-side: nothing round-tripped, no reload.
    expect(page.evaluate_script("window.__actionPosts")).to eq(0)
    expect(page.evaluate_script("window.__noReload")).to eq("alive")

    # The real submit reconciles both seeded rows via accepts_nested_attributes_for.
    find("[data-testid='create-order']").click
    expect(page).to have_css("[data-testid='item-count']", text: "2")

    order = Order.last
    expect(order.line_items.map { [it.quantity, it.price] }).to contain_exactly([3, 42], [1, 9])
  end

  it "clear: :reset puts every source back to its RENDERED default after each add (issue #466)" do
    visit "/draft_order_fill_reset"
    expect(page).to have_css("[data-testid='add-item']")

    # Change every source away from its default, then Add.
    find("[data-testid='src-qty']").set(5)
    find("[data-testid='src-price']").select("30")
    find("[data-testid='src-gift']").set(false)
    find("[data-testid='add-item']").click

    # The row got what was entered…
    expect(page).to have_css("[data-testid='item-row']", count: 1)
    row = page.first("[data-testid='item-row']")
    expect(row.find("[data-testid='qty']").value).to eq("5")
    expect(row.find("[data-testid='price']").value).to eq("30")
    expect(row.find("[data-testid='gift']")).not_to be_checked

    # …and the sources went back to their defaults, not to blank/unticked.
    expect(page).to have_field("src-qty", with: "1")
    expect(page).to have_select("src-price", selected: "20")
    expect(page).to have_checked_field("src-gift")

    # A second add straight away seeds the defaults (the default-on tick included).
    find("[data-testid='add-item']").click
    expect(page).to have_css("[data-testid='item-row']", count: 2)
    second = page.all("[data-testid='item-row']")[1]
    expect(second.find("[data-testid='qty']").value).to eq("1")
    expect(second.find("[data-testid='price']").value).to eq("20")
    expect(second.find("[data-testid='gift']")).to be_checked
    expect(page).to have_checked_field("src-gift")
  end

  it "fill-then-add composes with JSON mode — seeded rows serialize into the hidden field" do
    visit "/draft_order_fill_json"
    expect(page).to have_css("[data-testid='add-item']")
    install_fetch_spy

    find("[data-testid='src-qty']").set(5)
    find("[data-testid='src-price']").set(20)
    find("[data-testid='add-item']").click
    expect(page).to have_css("[data-testid='item-row']", count: 1)

    # The hidden JSON field carries the SEEDED values (not blanks).
    json = JSON.parse(page.find("[data-testid='json-field']", visible: false).value)
    expect(json).to eq([{ "quantity" => "5", "price" => "20" }])

    # Sources cleared, nothing round-tripped.
    expect(page).to have_field("src-qty", with: "")
    expect(page.evaluate_script("window.__actionPosts")).to eq(0)

    # Submit → the hand-rolled JSON.parse controller persists the seeded row.
    find("[data-testid='create-order']").click
    expect(page).to have_css("[data-testid='item-count']", text: "1")
    expect(Order.last.line_items.map { [it.quantity, it.price] }).to eq([[5, 20]])
  end
end
