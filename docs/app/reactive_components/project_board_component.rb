# frozen_string_literal: true

# The Project board (issue #216) — the kanban flagship. Three fixed lanes on
# ONE shared public board; each card is its own nested reactive root (see
# BoardCardComponent) owning rename/archive, while the board owns the per-lane
# composers, the effect-style picker (signed state, threaded into every row so
# per-call effects use the visitor's pick) and the MOVE: the lanes are
# sortable lists of one group (issue #350), so a card drags within its lane or
# into another, and the drop calls move_card with the card, the lane and the
# position it landed at.
#
# Count badges are kept live EVERYWHERE via reactive:js text ops — the actor's
# reply chains them (reply.js) and every mutation broadcasts them — closing
# the gap where a peer tab's badges go stale after a row broadcast. Empty
# lanes are pure CSS (the lane list's :empty pseudo shows the placeholder), so
# the 0↔1 boundary needs no bookkeeping on either path.
class ProjectBoardComponent < Phlex::HTML
  include Phlex::Reactive::Streamable
  include Phlex::Reactive::Component
  include Phlex::Rails::Helpers::TurboStreamFrom

  STYLES = %w[default fade slide scale highlight shake random].freeze
  LANE_TITLES = { 'todo' => 'To do', 'doing' => 'Doing', 'done' => 'Done' }.freeze

  # The lane list's :empty placeholder — rendered by CSS the moment the last
  # card leaves, restored the moment one arrives; no server bookkeeping.
  EMPTY_LANE_CSS = "empty:before:content-['No_cards_yet'] empty:before:block " \
                   'empty:before:rounded-field empty:before:border empty:before:border-dashed ' \
                   'empty:before:border-base-300 empty:before:py-4 empty:before:text-center ' \
                   'empty:before:text-xs empty:before:opacity-50'

  # The drag's styling hooks (issue #350): the lane being dragged over, and
  # the placeholder gap where the card would land.
  DRAG_CSS = 'data-[reactive-sortable-active]:outline data-[reactive-sortable-active]:outline-2 ' \
             'data-[reactive-sortable-active]:outline-offset-4 data-[reactive-sortable-active]:outline-primary/40 ' \
             '[&>[data-reactive-sortable-placeholder]]:rounded-field ' \
             '[&>[data-reactive-sortable-placeholder]]:border-2 [&>[data-reactive-sortable-placeholder]]:border-dashed ' \
             '[&>[data-reactive-sortable-placeholder]]:border-primary/40'

  reactive_state :style

  # Composer inputs are named PER LANE (title_todo/…): the client's field
  # sweep is root-wide, so three same-named inputs would collide (last wins);
  # the lane param picks the right one out of the declared trio.
  action :add_card, params: { title_todo: :string, title_doing: :string, title_done: :string, lane: :string }
  action :set_style, params: { style: :string }
  action :move_card, params: { item: :integer, lane: :string, position: :integer }

  def initialize(style: 'default')
    @style = STYLES.include?(style) ? style : 'default'
  end

  def id = 'project-board'

  class << self
    def lane_target(lane) = "lane-#{lane}-cards"

    # One js chain repainting all three count badges from server truth —
    # chained onto the actor's reply AND broadcast to peers after every
    # mutation, so no tab's badges ever go stale.
    def count_ops
      Card::LANES.reduce(Phlex::Reactive::JS.new) do |chain, lane|
        chain.text("#lane-#{lane}-count", Card.by_lane(lane).count)
      end
    end

    def broadcast_counts(exclude:)
      broadcast_to(*Card.stream_key, js: count_ops, exclude:)
    end
  end

  # Add into the named lane. The full-board re-render (the todo-list
  # precedent) clears the composer and repaints counts in one go; peers get
  # the row append + the count sync.
  def add_card(lane:, title_todo: '', title_doing: '', title_done: '')
    return reply.replace unless Card::LANES.include?(lane)

    title = { 'todo' => title_todo, 'doing' => title_doing, 'done' => title_done }.fetch(lane).to_s.strip
    return reply.replace.flash(:error, 'A card needs a title', dismiss_after: 2500) if title.blank?

    card = Card.create!(title:, lane:, position: Card.next_position(lane))
    BoardCardComponent.broadcast_to(*Card.stream_key, append: card,
                                                      target: self.class.lane_target(lane),
                                                      exclude: reactive_connection_id)
    self.class.broadcast_counts(exclude: reactive_connection_id)
    reply.replace
  end

  # A drop (issue #350): the card has already moved on the actor's screen. Save
  # the lane and position, morph the board (the server's order and counts win;
  # Idiomorph matches cards by id), then re-render the card itself so it lands
  # with an update effect — the picked style, or the row's declared highlight.
  # Peers get only the lanes the card left and entered (in the default style:
  # the pick is this visitor's) plus the count repaint — never the whole board,
  # so a peer's half-typed composer or rename elsewhere is left alone.
  def move_card(item:, lane:, position:)
    card = Card.find_by(id: item)
    return reply.morph unless card && Card::LANES.include?(lane)

    from = card.lane
    card.move_to!(lane, position)
    broadcast_lanes([from, lane].uniq)
    reply.morph.stream(BoardCardComponent.replace(card, morph: true, style: @style, effect: picked_effect))
  end

  # The effect-style picker: whitelisted, signed into state, and threaded into
  # every row on the re-render so subsequent moves animate with the pick.
  def set_style(style:)
    @style = style if STYLES.include?(style)
    reply.replace
  end

  def view_template
    div(**reactive_root(class: 'flex flex-col gap-4', data: { testid: 'project-board' })) do
      turbo_stream_from(*Card.stream_key) # cross-tab sync
      # The flash landing zone (Phlex::Reactive.flash_target default) — the
      # archive toast and the blank-title error append here.
      div(id: 'flash', class: 'flex flex-col gap-1', data: { testid: 'flash' })
      header_row
      div(class: 'grid gap-4 sm:grid-cols-3') do
        Card::LANES.each { |lane| lane_column(lane) }
      end
    end
  end

  private

  # A morph of each lane's CONTENT (the list keeps its own attributes), then
  # the count badges.
  def broadcast_lanes(lanes)
    lanes.each do |lane|
      BoardLaneComponent.broadcast_to(*Card.stream_key, update: { lane: }, morph: true,
                                                        exclude: reactive_connection_id)
    end
    self.class.broadcast_counts(exclude: reactive_connection_id)
  end

  def header_row
    div(class: 'flex flex-wrap items-center justify-between gap-2') do
      span(class: 'text-sm opacity-70') { 'Drag a card by its ⠿ handle — in every open tab.' }
      style_picker
    end
  end

  def style_picker
    div(class: 'join', data: { testid: 'style-picker' }) do
      STYLES.each do |name|
        button(**mix(on(:set_style, style: name),
                     class: "join-item btn btn-xs #{'btn-active' if name == @style}",
                     data: { testid: "style-#{name}" })) { name }
      end
    end
  end

  # 'default' defers to the row's declared effects; anything else overrides
  # per call. 'random' rides through — the client picks a built-in per
  # application.
  def picked_effect
    @style == 'default' ? nil : @style.to_sym
  end

  def lane_column(lane)
    div(class: 'flex flex-col gap-3 rounded-box border border-base-300 bg-base-200/50 p-3',
        data: { testid: "lane-#{lane}" }) do
      div(class: 'flex items-center justify-between') do
        h3(class: 'text-sm font-semibold') { LANE_TITLES.fetch(lane) }
        span(id: "lane-#{lane}-count", class: 'badge badge-sm', data: { testid: "count-#{lane}" }) do
          Card.by_lane(lane).count.to_s
        end
      end
      ul(id: self.class.lane_target(lane), class: "flex min-h-12 flex-col gap-2 #{EMPTY_LANE_CSS} #{DRAG_CSS}",
         **lane_sortable(lane)) do
        render BoardLaneComponent.new(lane:, style: @style)
      end
      composer(lane)
    end
  end

  # Every lane is a sortable of the "cards" group: a card drags within it or
  # into another lane. `name:` is what a card dragged OUT of this lane reports
  # as `from`; `params:` tells move_card which lane it landed in.
  def lane_sortable(lane)
    reactive_sortable(:move_card, group: 'cards', name: lane, params: { lane: },
                                  handle: '[data-drag-handle]')
  end

  def composer(lane)
    div(class: 'flex gap-2') do
      input(**mix(on(:add_card, lane:, event: 'keydown.enter'),
                  name: "title_#{lane}", placeholder: 'Add a card…', autocomplete: 'off',
                  class: 'input input-sm input-bordered min-w-0 flex-1',
                  data: { testid: "new-card-#{lane}" }))
      button(**mix(on(:add_card, lane:, busy: '…'),
                   class: 'btn btn-sm btn-primary', data: { testid: "add-#{lane}" })) { 'Add' }
    end
  end
end
