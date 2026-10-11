# frozen_string_literal: true

module Views
  module Docs
    module Pages
      class ExampleProjectBoard < DocsUI::Page
        title 'Example: Project board (the kanban flagship)'
        eyebrow 'Examples'
        description 'Build a live kanban board in reactive Phlex: drag cards within and across lanes ' \
                    '(mouse, touch or keyboard), live count badges in every open tab, inline rename, and ' \
                    'a confirm-gated archive.'

        def lead
          'One shared board, three lanes. Drag a card to reorder it or move it to another lane — ' \
            'one declared action, one morph, every count badge repainted — live in every open tab, ' \
            'with no Stimulus controller and no hand-picked Turbo target.'
        end

        def content
          try_it
          whats_here
          the_move
          the_row
          live_counts
          notes
        end

        private

        def try_it
          DocsUI::Section('Try it') do
            md <<~MD
              A real kanban. Drag a card by its **⠿** handle — within its lane or
              into another — with a mouse or a finger. Or focus a card, press
              **Space**, move it with the arrow keys (**← →** across lanes) and
              press **Space** again. Rename a card inline and press **Enter** — the
              morph keeps your caret.
              **×** archives through a confirm gate and hides the card optimistically.
              Open this page in a second tab: every move, add, rename, and archive
              arrives there live, count badges included.
            MD
            render Views::Examples::LatencyToggle.new(delay_ms: 700)
            render Views::Examples::LiveExample.new(
              component: ProjectBoardComponent.new,
              filename: 'app/components/project_board_component.rb'
            )
          end
        end

        def whats_here
          DocsUI::Section('Every feature, in one board') do
            md <<~MD
              | Feature | Where |
              |---|---|
              | **Sortable lists** — the lanes are one drag group; a drop calls `move_card` with the card, lane and position | the lanes |
              | **Effects** — declared enter/exit/update on the row, per-call override from the style picker | the move / the picker |
              | **Nested reactive roots** — each card is its own root inside the board (its rename input stays its own) | the row |
              | **Record + state identity** — the card's GlobalID AND the picked style in one signed token | the row |
              | **`reply.remove(...).js(...).flash(...)`** — one reply removes the card, repaints every badge and confirms | `archive` |
              | **Live peer counts** — `broadcast_to(js:)` text ops keep every tab's badges honest | every mutation |
              | **Inline rename + morph** — Enter saves; focus and caret survive | the row |
              | **`confirm:` + optimistic hide** — archive gates, then hides in the same gesture | the row |
              | **Per-lane composers** — `busy:` dedupes, a blank title gets an error flash | the board |
              | **CSS `:empty` lanes** — the placeholder needs zero bookkeeping on either path | the lane list |
            MD
          end
        end

        def the_move
          DocsUI::Section('The move — drag, drop, one action') do
            md <<~'MD'
              Each lane is a [sortable list](/docs/sortable-lists) of the
              `cards` group, so a card drags within its lane or into another.
              `name:` is what a card dragged out of the lane reports as `from`;
              `params:` tells the action which lane it landed in:

              ```ruby
              action :move_card, params: { item: :integer, lane: :string, position: :integer }

              ul(id: "lane-#{lane}-cards",
                 **reactive_sortable(:move_card, group: "cards", name: lane, params: { lane: },
                                                 handle: "[data-drag-handle]")) do
                Card.by_lane(lane).each { render BoardCardComponent.new(card: it) }
              end

              # BoardCardComponent: the card is the sortable item, its ⠿ the handle.
              li(**mix(reactive_root, reactive_sortable_item(@card.id))) do
                span(data: { drag_handle: true }) { "⠿" }
                # …
              end
              ```

              The card has already moved on your screen when the request goes
              out. The action saves the lane and position, then morphs the board:
              the server's order wins (Idiomorph matches cards by id) and the
              count badges repaint in the same reply. A second stream re-renders
              the card itself so it lands with an **update effect**: the style
              you picked, or the row's declared highlight. Peers get the same
              morph, with the actor's echo excluded. If the action fails, the
              card goes back to where it was:

              ```ruby
              def move_card(item:, lane:, position:)
                card = Card.find_by(id: item)
                return reply.morph unless card && Card::LANES.include?(lane)

                card.move_to!(lane, position)
                self.class.broadcast_to(*Card.stream_key, replace: self.class.new, morph: true,
                                                          exclude: reactive_connection_id)
                reply.morph.stream(BoardCardComponent.replace(card, morph: true, style: @style,
                                                                    effect: picked_effect))
              end
              ```

              `picked_effect` is the style picker's choice, signed into the
              board's state — `default` defers to the row's declared effects,
              anything else overrides **per call** (the issue #215 three-level
              precedence, live).
            MD
          end
        end

        def the_row
          DocsUI::Section('Why each card is its own reactive root') do
            md <<~MD
              The card carries a rename `<input name="title">`. Field collection
              is **root-wide**, so if the rows were tokenless (the team-inbox
              pattern) every card's title would land in the board's sweep and the
              last one would win. Making each card a **nested reactive root**
              (issue #15) gives every row its own field scope, its own signed
              identity — the Card's GlobalID plus the picked style — and its own
              `rename`/`archive` actions. The board keeps what is genuinely
              board-level: the composers, the style picker, and the move (a drop
              is about the lanes, not the card).

              The card being a nested root does not get in the drag's way: a row
              belongs to the closest sortable list in its own root, so the card
              is an item of the board's lane.
            MD
          end
        end

        def live_counts
          DocsUI::Section('Live counts in every tab') do
            md <<~'MD'
              Row broadcasts alone leave a peer's count badges stale — the
              collection bookkeeping in a reply is the **actor's** HTTP response.
              The board closes that gap with one `reactive:js` chain repainting
              all three badges from server truth, chained onto the actor's reply
              (`reply.js`) AND broadcast to peers after every mutation:

              ```ruby
              def self.count_ops
                Card::LANES.reduce(Phlex::Reactive::JS.new) do |chain, lane|
                  chain.text("#lane-#{lane}-count", Card.by_lane(lane).count)
                end
              end

              def self.broadcast_counts(exclude:)
                broadcast_to(*Card.stream_key, js: count_ops, exclude:)
              end
              ```

              Empty lanes need no bookkeeping at all: the lane list styles its
              own `:empty` pseudo-class, so the placeholder appears the moment
              the last card leaves — on the actor's reply and the peer's
              broadcast alike.
            MD
          end
        end

        def notes
          DocsUI::Section('Notes') do
            md <<~MD
              - The board is **one shared instance** for every visitor — that's
                what makes the second-tab story visible between strangers. Seeds
                restore a starting set on boot.
              - A move is **optimistic** by nature: the card is where you dropped
                it before the reply arrives, and goes back if the action fails.
                Archive is optimistic too — the confirm gate already slowed it
                down.
              - Peers receive the moved board with the default effect style: the
                style picker is each visitor's own choice.
              - Cross-tab delivery runs on whatever transport the app has —
                Action Cable here, [pgbus](/docs/transport-pgbus) in production —
                the component code is identical.
              - The composer inputs are named per lane (`title_todo`, …): the
                client's field sweep is root-wide, and three same-named inputs
                would collide.
            MD
          end
        end
      end
    end
  end
end
