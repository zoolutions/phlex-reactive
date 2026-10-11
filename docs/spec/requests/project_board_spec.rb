# frozen_string_literal: true

require 'rails_helper'
require 'turbo/broadcastable/test_helper'

# The Project board flagship (issue #216): a kanban with three fixed lanes.
# Each card is its OWN nested reactive root (record + signed style state). A
# card moves by DRAG (issue #350): the lanes are sortable lists of one group,
# and a drop calls the board's move_card with the card, its lane and its new
# position; the board morphs (counts included) and peers get the same morph.
RSpec.describe 'Project board actions', type: :request do
  include ActiveSupport::Testing::Assertions
  include Turbo::Broadcastable::TestHelper

  before { Card.delete_all }

  def card_payload(card, style: 'default') = { 'gid' => card.to_gid.to_s, 's' => { 'style' => style } }
  def board_payload(style: 'default') = { 's' => { 'style' => style } }

  describe 'the demo page' do
    it 'renders three lanes with seeded cards and counts' do
      Card.create!(title: 'Ship the board', lane: 'todo')
      Card.create!(title: 'Review PR', lane: 'doing')

      get '/demos/project-board'

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('lane-todo-cards')
      expect(response.body).to include('lane-doing-cards')
      expect(response.body).to include('lane-done-cards')
      expect(response.body).to include('Ship the board')
      expect(response.body).to include('lane-todo-count')
    end
  end

  describe 'ProjectBoardComponent#move_card (a drag, issue #350)' do
    let!(:first) { Card.create!(title: 'First', lane: 'todo', position: 1) }

    before do
      Card.create!(title: 'Second', lane: 'todo', position: 2)
      Card.create!(title: 'Doing', lane: 'doing', position: 1)
    end

    def move(item, lane, position, style: 'default')
      post_action(ProjectBoardComponent, payload: board_payload(style:), act: 'move_card',
                                         params: { item:, lane:, position:, after: nil, from: 'todo' })
    end

    it 'moves the card into the lane at the dropped position and morphs the board' do
      move(first.id, 'doing', 0)

      expect(response).to have_http_status(:ok)
      expect(Card.by_lane('doing').map(&:title)).to eq(%w[First Doing])
      expect(Card.by_lane('todo').map(&:title)).to eq(%w[Second])
      expect(response.body).to include('method="morph"', 'target="project-board"')
    end

    it 'reorders within a lane' do
      move(first.id, 'todo', 1)

      expect(Card.by_lane('todo').map(&:title)).to eq(%w[Second First])
    end

    it 'clamps a position past the end to the bottom of the lane' do
      move(first.id, 'doing', 99)

      expect(Card.by_lane('doing').map(&:title)).to eq(%w[Doing First])
    end

    it 'keeps the picked style across the move (signed state)' do
      move(first.id, 'doing', 0, style: 'scale')

      # (A turbo-stream body: parsed_body does not parse it as HTML.)
      picker = Nokogiri::HTML5.fragment(response.body).at_css("[data-testid='style-scale']")
      expect(picker['class']).to include('btn-active')
    end

    it 're-renders the moved card with the picked style as a per-call effect' do
      move(first.id, 'doing', 0, style: 'scale')

      expect(response.body).to include(%(target="#{BoardCardComponent.new(card: first).id}"), 'data-reactive-effect="scale"')
    end

    it "leaves the card's stream unstamped on the default style (the row's declared update effect rules)" do
      move(first.id, 'doing', 0)

      expect(response.body).not_to include('data-reactive-effect=')
    end

    it 'rejects an unknown lane or card without moving anything' do
      move(first.id, 'trash', 0)
      move(0, 'doing', 0)

      expect(first.reload.lane).to eq('todo')
      expect(Card.by_lane('doing').map(&:title)).to eq(%w[Doing])
    end

    it 'broadcasts only the two lanes it touched (a morph of their cards) and the counts — never the board' do
      broadcasts = capture_turbo_stream_broadcasts(Card.stream_key) do
        move(first.id, 'doing', 0)
      end
      html = broadcasts.map(&:to_s).join # rubocop:disable Style/MapJoin

      expect(html).to include('action="update" target="lane-todo-cards"', 'action="update" target="lane-doing-cards"')
      expect(html).to include('method="morph"', 'action="reactive:js"', 'lane-doing-count')
      expect(html).not_to include('target="project-board"', 'lane-done-cards')
    end
  end

  describe 'the lanes' do
    it 'are sortable lists of one group, each naming its lane, with a drag handle per card' do
      Card.create!(title: 'Drag me', lane: 'todo', position: 1)

      get '/demos/project-board'

      body = response.body
      expect(body).to include('data-reactive-sortable="move_card"', 'data-reactive-sortable-group="cards"')
      expect(body).to include('data-reactive-sortable-name="doing"', 'data-reactive-sortable-handle="[data-drag-handle]"')
      expect(body).to include('data-reactive-sortable-item=', 'data-drag-handle')
      expect(body).not_to include('data-testid="move-doing"')
    end
  end

  describe 'BoardCardComponent#rename' do
    let!(:card) { Card.create!(title: 'Old title', lane: 'todo') }

    it 'renames and morphs the row in place (focus survives)' do
      post_action(BoardCardComponent, payload: card_payload(card), act: 'rename',
                                      params: { title: 'New title' })

      expect(card.reload.title).to eq('New title')
      expect(response.body).to include('method="morph"')
    end

    it 'keeps the old title on a blank rename' do
      post_action(BoardCardComponent, payload: card_payload(card), act: 'rename', params: { title: '   ' })

      expect(card.reload.title).to eq('Old title')
    end
  end

  describe 'BoardCardComponent#archive' do
    let!(:card) { Card.create!(title: 'Done with this', lane: 'done') }

    it 'destroys the card, removes the row, repaints counts, and confirms with a flash' do
      expect do
        post_action(BoardCardComponent, payload: card_payload(card), act: 'archive')
      end.to change(Card, :count).by(-1)

      expect(response.body).to include('action="remove"')
      expect(response.body).to include('action="reactive:js"')
      expect(response.body).to include('data-reactive-dismiss-after="2000"')
    end
  end

  describe 'ProjectBoardComponent#add_card' do
    # Composer inputs are named PER LANE (title_todo/…) — the client's field
    # sweep is root-wide, so same-named inputs would collide; the lane param
    # picks the right one.
    it 'creates the card and re-renders the board (composer clears, counts fresh)' do
      expect do
        post_action(ProjectBoardComponent, payload: board_payload, act: 'add_card',
                                           params: { title_todo: 'New card', lane: 'todo' })
      end.to change(Card, :count).by(1)

      expect(response.body).to include('New card')
      expect(response.body).to include('action="replace"')
    end

    it 'rejects a blank title with an error flash, creating nothing' do
      expect do
        post_action(ProjectBoardComponent, payload: board_payload, act: 'add_card',
                                           params: { title_todo: '   ', lane: 'todo' })
      end.not_to change(Card, :count)

      expect(response.body).to include('reactive-flash--error')
    end

    it 'refuses an unknown lane, creating nothing' do
      expect do
        post_action(ProjectBoardComponent, payload: board_payload, act: 'add_card',
                                           params: { title_todo: 'Sneaky', lane: 'trash' })
      end.not_to change(Card, :count)
    end

    it 'broadcasts the new row + count sync to peers' do
      broadcasts = capture_turbo_stream_broadcasts(Card.stream_key) do
        post_action(ProjectBoardComponent, payload: board_payload, act: 'add_card',
                                           params: { title_doing: 'Broadcast me', lane: 'doing' })
      end
      html = broadcasts.map(&:to_s).join # rubocop:disable Style/MapJoin

      expect(html).to include(%(target="lane-doing-cards"))
      expect(html).to include('action="reactive:js"')
    end
  end

  describe 'ProjectBoardComponent#set_style' do
    it 'signs the whitelisted style into state and re-renders with it active' do
      post_action(ProjectBoardComponent, payload: board_payload, act: 'set_style',
                                         params: { style: 'shake' })

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('action="replace"')
    end

    it 'ignores an unknown style' do
      post_action(ProjectBoardComponent, payload: board_payload, act: 'set_style',
                                         params: { style: 'evil' })

      expect(response).to have_http_status(:ok)
    end
  end
end
