# frozen_string_literal: true

require "rails_helper"

# Issue #350: the dummy's sortable list (state-backed). A drop of a key the list
# does not hold (a stale tab, a forged request) must not manufacture a row.
RSpec.describe SortableListComponent, type: :request do
  let(:tasks) { %w[alpha bravo] }

  def drop(item, position)
    post_action(described_class, act: "move", payload: { "s" => { "tasks" => tasks, "fail" => false, "last" => "" } },
      params: { item:, position:, after: nil, from: "self" })
  end

  it "reorders a known row" do
    drop("bravo", 0)

    expect(response.body.scan("data-reactive-sortable-item").size).to eq(2)
    expect(response.body.index("bravo")).to be < response.body.index("alpha")
  end

  it "ignores an unknown row instead of inserting it" do
    drop("ghost", 0)

    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include("ghost")
  end
end
