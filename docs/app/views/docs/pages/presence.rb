# frozen_string_literal: true

module Views
  module Docs
    module Pages
      class Presence < DocsUI::Page
        title 'Presence'
        eyebrow 'Guide'
        description 'Who is viewing a stream — one entry per tab, each with its own small state — on a roster ' \
                    'component that re-renders itself for every viewer. No controller code, no JavaScript.'

        def lead
          'Declare `reactive_presence :viewers` on a component and read `presence` in its view: who has the ' \
            'page open, one peer per browser tab, grouped by person, each with the state you declared. A tab ' \
            'joining, leaving, going silent or changing its state re-renders the roster in every tab.'
        end

        def content
          try_it
          the_roster
          state_section
          authorization
          me_and_styling
          events
          leaving
          transport
          reference
        end

        private

        def try_it
          DocsUI::Section('Try it') do
            if Phlex::Reactive::Presence.capable?
              md <<~MD
                Open this page in a second tab, then pick a colour in either
                one. Your own dot is filled; the other tab's is an outline.
                Close the second tab and its dot goes away.
              MD
              # The roster mints its own <pgbus-stream-source>; load the element.
              script(type: 'module') { raw safe(%(import "pgbus/stream_source_element")) } # rubocop:disable Rails/OutputSafety
              render Views::Examples::LiveExample.new(component: PresenceDemoComponent.new, source: demo_source,
                                                      filename: 'app/reactive_components/presence_demo_component.rb')
            else
              DocsUI::Callout(:note, title: 'The live demo needs per-connection presence') do
                md <<~MD
                  This site's transport does not have it yet: presence needs a
                  pgbus release with zoolutions/pgbus#515. The code below is the
                  demo's.
                MD
              end
              render Views::Examples::Code.new(demo_source)
            end
          end
        end

        def the_roster
          DocsUI::Section('A roster') do
            md <<~MD
              ```ruby
              class Boards::Viewers < Phlex::HTML
                include Phlex::Reactive::Component

                reactive_record :board
                reactive_presence :viewers, state: { selected: :integer }, ttl: 45

                def initialize(board:) = @board = board

                def view_template
                  div(**reactive_root) do
                    presence.members.each do |member|
                      span(**reactive_presence_member(member)) { member.metadata["name"] }
                    end
                  end
                end
              end
              ```

              The stream is `[board, :presence, :viewers]`. The root subscribes
              to it by itself: the client mints a hidden
              `<pgbus-stream-source presence>` for it, which sends the tab's
              seat, and a tab joins when that connects. A record-less roster
              names its stream with `key: ["lobby"]`.

              `presence` is the roster as this render reads it:

              | Method | Returns |
              |---|---|
              | `peers` | one per tab: `seat`, `member_id`, `metadata`, `state`, `joined_at` |
              | `members` | grouped by person: `id`, `metadata`, `seats`, `state` (the newest tab's) |
              | `where(**state)` | the peers whose state matches |
              | `count` / `empty?` | tabs (`members.size` for people) |
              | `me` | the acting tab's peer, in an action |
              | `set(**state)` | in an action: write the acting tab's state |

              `metadata` is what the transport's identity extractor returns for
              the connection (pgbus's `streams_presence_member`): a name, an
              avatar URL. Two presence roots in one tab are one peer.
            MD
          end
        end

        def state_section
          DocsUI::Section('Per-tab state') do
            md <<~MD
              `state:` declares what each tab may carry, typed like action
              params; undeclared keys are dropped. Set it from the browser with
              the `js.presence` op:

              ```ruby
              li(**on_client(:click, js.presence(selected: card.id))) do
                plain card.title
                presence.where(selected: card.id).each do |peer|
                  span(**reactive_presence_peer(peer), class: "dot")
                end
              end
              ```

              It goes through the generated `presence_set` action — the signed
              token, the typed params, the request queue. Only this tab's row
              changes; the other tabs get a morph and this tab gets
              `reply.morph`. From an action of your own, `presence.set(selected: id)`
              does the same. A tab that reconnects sends its state again.
            MD
          end
        end

        def authorization
          DocsUI::Section('Authorization') do
            md <<~MD
              `presence_set` is exempt from `verify_authorized`. The token
              proves the actor rendered this root; the write is typed,
              ephemeral, and lands only on the actor's own row, keyed by the
              tab's SSE connection id, which no other tab knows. When the value
              needs a check, define `authorize_presence_state!` and raise:

              ```ruby
              def authorize_presence_state!(selected: nil)
                raise NotAllowed unless selected.nil? || @board.cards.exists?(selected)
              end
              ```

              Register the error in `Phlex::Reactive.authorization_errors` and a
              refused write is a 403 that changes nothing.
            MD
          end
        end

        def me_and_styling
          DocsUI::Section('This tab, and styling') do
            md <<~MD
              The roster is rendered once for every viewer, so the server
              cannot mark "you". After every paint the client marks:

              | Attribute | On |
              |---|---|
              | `data-reactive-presence-me` | this tab's `reactive_presence_peer` element |
              | `data-reactive-presence-same-member` | the same person's other elements (their other tabs, their avatar) |

              `reactive_presence_peer(peer)` and `reactive_presence_member(member)`
              render the attributes the client reads (`-peer`, `-member`,
              `-seats`). Combine them with your own attributes through `mix`.
            MD
          end
        end

        def events
          DocsUI::Section('Events') do
            md <<~MD
              After a morph that changes who is there, the root fires
              `reactive:presence` with `{ joined: [seat…], left: [seat…], me: seat }`.
              It is computed from the page, so a replayed frame that changes
              nothing fires nothing:

              ```ruby
              div(**mix(reactive_root, on_client("reactive:presence", js.add_class(:root, "pulse"))))
              ```
            MD
          end
        end

        def leaving
          DocsUI::Section('Leaving and expiry') do
            md <<~MD
              Closing a tab leaves at once. A tab that goes silent (a laptop
              asleep, a lost network) expires after `ttl:` seconds (45 by
              default; it is written into pgbus's `streams_presence_ttl` at
              boot, under this stream's pattern); the transport's heartbeat
              keeps a live tab fresh. Each join, leave and
              expiry renders the roster once, in a job on `defer_job_queue`,
              from the table as it is then, so a page reload (a leave and a
              join within milliseconds) is one morph with the tab still there.
            MD
          end
        end

        def transport
          DocsUI::Section('Transport') do
            md <<~MD
              Presence needs pgbus with presence keyed by SSE connection
              (zoolutions/pgbus#515), its seat table migrated
              (`rails g pgbus:add_presence_seats`, which `rails pgbus:update`
              queues), and ActiveJob. At boot the gem registers
              the presence stream pattern and its change hook; without that
              capability it does nothing at boot, and rendering a presence root
              raises `Phlex::Reactive::ConfigurationError`. Action Cable has no
              connection identity, so there is no fallback. The page must load
              pgbus's client element (`import "pgbus/stream_source_element"`;
              any `pgbus_stream_from` on the page already does).
            MD
          end
        end

        def reference
          DocsUI::Section('Reference') do
            md <<~MD
              ```ruby
              reactive_presence(name, state: {}, ttl: 45, key: nil)
              presence                         # the roster
              reactive_presence_peer(peer)     # data-reactive-presence-peer / -member
              reactive_presence_member(member) # data-reactive-presence-member / -seats
              js.presence(**state)             # client op (refused on a broadcast)
              ```

              `reactive_presence` raises an `ArgumentError` for a name that is
              not a lowercase identifier, a `ttl:` that is not a positive
              Integer, the reserved state key `_rp`, or a dormant component (a
              dormant root never connects). The client is the `presence`
              feature module (1.1 KB gzipped); the split client loads it only
              for a page with a presence root.
            MD
          end
        end

        def demo_source = Rails.root.join('app/reactive_components/presence_demo_component.rb').read.strip
      end
    end
  end
end
