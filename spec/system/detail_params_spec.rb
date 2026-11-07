# frozen_string_literal: true

require "system_helper"

# Issue #462, end to end in a real browser: ItemCreatorComponent's reply
# dispatches app:item-created with the new item's id in the detail;
# FilteredItemsComponent's root is bound to that event with
# on(:show_new_item, event: "app:item-created", window: true, detail_params: { id: :id }),
# so its action receives the id as a typed param and prepends the row only when
# the title fits the list's own filter. The creator never touches the list.
RSpec.describe "A list reacts to a sibling's event with detail_params: (issue #462)", type: :system do
  # Every POST body, and every round trip the list's root applied (the
  # reactive:applied lifecycle event, issue #79) counted into a node a waiting
  # matcher can read — a miss changes nothing else in the page.
  def install_probes
    page.execute_script(<<~JS)
      window.__posts = []
      const original = window.fetch
      window.fetch = (url, opts) => {
        if (typeof opts?.body === "string") window.__posts.push(JSON.parse(opts.body))
        return original(url, opts)
      }
      const applied = document.createElement("span")
      applied.dataset.testid = "list-applied"
      applied.textContent = "0"
      document.body.append(applied)
      document.getElementById("filtered-items-list").addEventListener("reactive:applied", () => {
        applied.textContent = String(Number(applied.textContent) + 1)
      })
      window.__marker = "kept"
    JS
  end

  def visit_page(query = nil)
    visit "/detail_params#{"?#{query}" if query}"
    find("#item-creator[data-reactive-connected]")
    find("#filtered-items-list[data-reactive-connected]")
    install_probes
  end

  def create_item(title, created:)
    find("[data-testid='new-item']").set(title)
    find("[data-testid='create']").click
    expect(page).to have_css("[data-testid='created-count']", exact_text: created.to_s)
  end

  def wait_for_list_round_trips(count)
    expect(page).to have_css("[data-testid='list-applied']", exact_text: count.to_s)
  end

  def list_posts = page.evaluate_script("window.__posts.filter((post) => post.act === 'show_new_item')")

  it "posts the detail's id as the list's param and prepends the row when nothing filters it out" do
    visit_page
    token = page.evaluate_script("document.getElementById('filtered-items-list').dataset.reactiveTokenValue")

    create_item("Milk", created: 1)

    expect(page).to have_css("[data-testid='filtered-item']", exact_text: "Milk")
    wait_for_list_round_trips(1)
    expect(list_posts).to eq([{ "token" => token, "act" => "show_new_item", "params" => { "id" => Todo.last.id } }])
    expect(page.evaluate_script("window.__marker")).to eq("kept")
  end

  it "keeps a row the list's own filter refuses out, and lets a matching one in" do
    visit_page("filter=milk")
    expect(page).to have_css("[data-testid='filter']", exact_text: "Showing: milk")

    create_item("Bread", created: 1)
    wait_for_list_round_trips(1)

    expect(page).to have_no_css("[data-testid='filtered-item']")
    expect(list_posts.map { it["params"] }).to eq([{ "id" => Todo.find_by!(title: "Bread").id }])

    create_item("Oat milk", created: 2)

    expect(page).to have_css("[data-testid='filtered-item']", exact_text: "Oat milk")
    wait_for_list_round_trips(2)
    expect(page).to have_no_css("[data-testid='filtered-item']", text: "Bread")
    expect(page.evaluate_script("window.__marker")).to eq("kept")
  end

  it "prepends newest first, above the rows rendered on first paint" do
    Todo.create!(title: "Milk")
    visit_page

    create_item("Oat milk", created: 1)

    expect(page).to have_css("[data-testid='filtered-item']", count: 2)
    expect(page.all("[data-testid='filtered-item']").map(&:text)).to eq(["Oat milk", "Milk"])
  end
end
