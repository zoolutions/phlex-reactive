# frozen_string_literal: true

# The cards of one Project board lane (issue #350) — the CONTENT of the lane's
# sortable <ul id="lane-…-cards">, not the list itself. The board renders it
# inside the list; after a drop, peers get `update` of just the lanes the card
# left and entered, so nothing else on their board is touched: a half-typed
# composer or another lane is never re-rendered under them. (The list element
# keeps its sortable attributes: an update replaces children only.)
class BoardLaneComponent < Phlex::HTML
  include Phlex::Reactive::Streamable

  def initialize(lane:, style: 'default')
    @lane = lane
    @style = style
  end

  def id = ProjectBoardComponent.lane_target(@lane)

  def view_template
    Card.by_lane(@lane).each { render BoardCardComponent.new(card: it, style: @style) }
  end
end
