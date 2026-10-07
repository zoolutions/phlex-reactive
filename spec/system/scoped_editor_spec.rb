# frozen_string_literal: true

require "system_helper"

# Issue #337: a `reactive_scope :todo` component with a FLAT schema, saved by a
# real browser. The client's default JSON body keeps the input's name verbatim
# ("todo[title]"), so this is the wire shape a request spec given a nested hash
# never sent — and the one the endpoint used to drop.
RSpec.describe "reactive_scope save from a real browser (issue #337)", type: :system do
  it "saves a scoped field posted as JSON" do
    todo = Todo.create!(title: "old")

    visit "/scoped_editor/#{todo.id}"
    page.execute_script("window.__noReload = 'alive'")

    find("[data-testid='title']").fill_in(with: "Buy milk")
    find("[data-testid='save']").click

    # The morph barrier: server-rendered text that only moves on a real save
    # (the input already shows what was typed, saved or not).
    expect(page).to have_css("[data-testid='saved-title']", text: "Buy milk")
    expect(todo.reload.title).to eq("Buy milk")
    expect(page.evaluate_script("window.__noReload")).to eq("alive")
  end
end
