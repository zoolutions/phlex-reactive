# frozen_string_literal: true

module Views
  module Docs
    module Pages
      class SortableLists < DocsUI::Page
        title 'Sortable lists'
        eyebrow 'Guide'
        description 'Drag rows to reorder a list, or drag them in from another list, with mouse, touch or ' \
                    'keyboard — one declared action receives the row and its new position. No JavaScript.'

        def lead
          'Mark a list `reactive_sortable(:move)` and its rows `reactive_sortable_item(key)`: rows drag ' \
            'with a mouse, a finger or the keyboard, move at once, and one declared action gets the row ' \
            'and where it landed — through the normal action pipeline.'
        end

        def content
          try_it
          the_list
          params_section
          drag_in
          between_lists
          keyboard
          styling
          failure
          reference
        end

        private

        def try_it
          DocsUI::Section('Try it') do
            md <<~MD
              Drag a task by its **⠿** handle to reorder it, or drag a template
              into the list to add a copy. Then try the keyboard: **Tab** to a
              task, **Space** to pick it up, **↑ ↓** to move it, **Space** to
              drop it (**Escape** puts it back). Turn the latency toggle on to
              see that the row moves at once, before the reply arrives.
            MD
            render Views::Examples::LatencyToggle.new(delay_ms: 600)
            render Views::Examples::LiveExample.new(component: SortableDemoComponent.new, source: demo_source,
                                                    filename: 'app/reactive_components/sortable_tasks_component.rb')
          end
        end

        def the_list
          DocsUI::Section('A sortable list') do
            md <<~MD
              Two helpers. `reactive_sortable(action)` goes on the list, and
              `reactive_sortable_item(key)` on each row. The key is a String or
              an Integer — usually the record's id — and travels as-is:

              ```ruby
              class TaskList < Phlex::HTML
                include Phlex::Reactive::Component

                reactive_record :list
                action :move, params: { item: :integer, position: :integer }

                def move(item:, position:)
                  authorize! @list, :update?
                  @list.tasks.find(item).insert_at(position + 1)   # acts_as_list is 1-based
                  reply.morph
                end

                def view_template
                  ul(**mix(reactive_root, reactive_sortable(:move, handle: "[data-drag-handle]"))) do
                    @list.tasks.each do |task|
                      li(id: dom_id(task), **reactive_sortable_item(task.id)) do
                        span(data: { drag_handle: true }) { "⠿" }
                        plain task.title
                      end
                    end
                  end
                end
              end
              ```

              The list can be the root itself (as here) or any element inside
              it. `handle:` is a CSS selector resolved inside each row; only it
              starts a drag. Without it the whole row drags — except a press on
              a form field in the row, so typing still works.

              A drag starts after a 4 px move, or on touch after a 200 ms press,
              so clicks, taps and scrolling on the rows behave as before. Near
              the top or bottom edge of a scrolling list, or of the window, the
              page scrolls.
            MD
          end
        end

        def params_section
          DocsUI::Section('What the action receives') do
            md <<~MD
              On drop the client sends the action once, with these params.
              Declare the ones you want — the rest are dropped, as for any
              action:

              | Param | Value |
              |---|---|
              | `item` | the dragged row's key |
              | `position` | its 0-based index in the list after the drop |
              | `after` | the key of the row it now follows, `nil` when it is first |
              | `from` | `"self"` for a reorder; the source list's name for a drag-in |

              A drop back where the row started sends nothing. The request goes
              through the root's own pipeline: the signed token, the request
              queue, `reactive:before-dispatch`, the busy state and the reply.
              `busy:` takes the same values as `on(busy:)` and applies to the
              list while the request is pending.
            MD
          end
        end

        def drag_in
          DocsUI::Section('Dragging in from another list') do
            md <<~MD
              `reactive_sortable_source(group:, name:)` marks a list whose rows
              are **copied** into any sortable of the same group, never moved.
              It needs no token, so it works on a `Phlex::Reactive::ClientBindings`
              root:

              ```ruby
              ul(**reactive_sortable_source(group: "tasks", name: "templates")) do
                TEMPLATES.each { |key, title| li(**mix(reactive_sortable_item(key), tabindex: -1)) { title } }
              end

              # The target joins the group, and maps the source's name to an action:
              ol(**reactive_sortable(:move, group: "tasks", from: { templates: :insert })) { … }

              action :insert, params: { item: :string, position: :integer }
              ```

              A source's rows are drag-only (the keyboard moves rows of a
              sortable, not copies), so `tabindex: -1` keeps them out of the
              tab order.

              While you drag, a copy of the row follows the pointer and the
              placeholder shows where it would land. On drop nothing is inserted
              in the browser: the target's action decides, and its reply renders
              the new row. Without a `from:` entry, a drag-in calls the list's
              own action, with `from` set to the source's name.
            MD
          end
        end

        def between_lists
          DocsUI::Section('Moving rows between lists') do
            md <<~MD
              Sortables of the same `group:` exchange rows — a kanban. Each list
              names itself (`name:`, what a row dragged out of it reports as
              `from`) and passes static `params:` so one action knows which list
              the row landed in. The [Project board](/docs/example-project-board)
              is built this way:

              ```ruby
              ul(**reactive_sortable(:move_card, group: "cards", name: lane, params: { lane: })) { … }

              action :move_card, params: { item: :integer, lane: :string, position: :integer }
              ```

              A row is an item of the closest sortable inside its own reactive
              root, so rows that are nested roots themselves (a card with its
              own rename input) still drag as items of the list around them.
            MD
          end
        end

        def keyboard
          DocsUI::Section('Keyboard and screen readers') do
            md <<~MD
              Each row is focusable (`tabindex="0"`). On a focused row:

              | Key | Does |
              |---|---|
              | **Space** / **Enter** | pick the row up; again to drop it (the action is sent) |
              | **↑** / **↓** | move it up or down |
              | **←** / **→** | move it into the previous / next list of its group |
              | **Escape** / **Tab** | put it back where it was |

              Each step is announced through an `aria-live="polite"` region:
              "Picked up item 3 of 7", "Moved to position 5 of 7", "Dropped",
              "Cancelled". The words come from the list, so translate them with
              `messages:` — `{position}` and `{count}` are filled in. (Not
              I18n's percent-brace interpolation: `t()` leaves these alone, so a
              locale string passes through as written.)

              ```ruby
              reactive_sortable(:move, messages: {
                picked: t(".picked"),       # "Element {position} von {count} aufgenommen"
                moved: t(".moved"),
                dropped: t(".dropped"),
                cancelled: t(".cancelled")
              })
              ```
            MD
          end
        end

        def styling
          DocsUI::Section('Styling the drag') do
            md <<~MD
              The look is yours. While a drag is on, the client sets these
              attributes — style them in CSS, or with Tailwind's `data-*`
              variants as the demo does:

              | Attribute | On |
              |---|---|
              | `data-reactive-sortable-active` | the list being dragged from or over |
              | `data-reactive-sortable-dragging` | the dragged row (or the copy of a source row) |
              | `data-reactive-sortable-placeholder` | the gap where the row would land (the row's height) |

              ```css
              [data-reactive-sortable-dragging] { box-shadow: 0 8px 24px rgb(0 0 0 / .2); }
              [data-reactive-sortable-placeholder] { border: 2px dashed var(--color-primary); border-radius: .5rem; }
              ```

              The dragged row follows the pointer with `position: fixed`; its
              inline style is put back when the drag ends.
            MD
          end
        end

        def failure
          DocsUI::Section('When the action fails') do
            md <<~MD
              The row moves at once and the request goes out. If the request
              fails — an HTTP error, a network error, a `reactive:before-dispatch`
              veto — the row goes back to where it was, and `reactive:error`
              fires as for any failed action. If the request succeeds but the
              reply does not render the list (no replace or update of the list
              or an element around it), the row also goes back, but no event
              fires: nothing failed. A reply
              that renders the list puts the rows in the server's order: Idiomorph
              matches them by id, so give every row a stable `id`.

              A drag is refused on a list or row marked `disabled: true`, and on
              a root with a request in flight.
            MD
          end
        end

        def reference
          DocsUI::Section('Reference') do
            md <<~MD
              ```ruby
              reactive_sortable(action, group: nil, handle: nil, name: nil, from: nil,
                                params: nil, disabled: false, busy: nil, messages: nil)
              reactive_sortable_source(group:, name: "source")
              reactive_sortable_item(key, disabled: false)
              ```

              Every argument is checked when the view renders: a blank action,
              handle or group, a `from:` that is not a Hash of list name to
              action, `params:` that set one of the drop params, an unknown
              `messages:` key, or a `reactive_sortable` on a client-only view
              raises an `ArgumentError` that says how to fix it. Under
              `verbose_errors`, an undeclared action raises too.

              The drag code is the client's `sortable` feature module (about
              3 KB gzipped). The default client bundles it; with the split client
              (`phlex/reactive/core`) a page without a sortable never loads it.
            MD
          end
        end

        def demo_source
          %w[sortable_tasks_component sortable_templates_component]
            .map { Rails.root.join("app/reactive_components/#{it}.rb").read.strip }
            .join("\n\n")
        end
      end
    end
  end
end
