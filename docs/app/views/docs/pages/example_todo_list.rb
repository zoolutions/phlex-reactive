# frozen_string_literal: true

module Views
  module Docs
    module Pages
      class ExampleTodoList < DocsUI::Page
        title 'Example: live todo list'
        eyebrow 'Examples'
        description 'Build a live Rails todo list from per-row reactive Phlex components: optimistic toggle and delete, inline rename via morph, and cross-tab Turbo Stream sync'

        def lead
          'Per-row reactive components with add / toggle / rename / archive — ' \
            'optimistic toggle and delete, Enter-to-add, a morph-preserved inline ' \
            'rename, a client-only tips toggle, and a broadcast on every change so ' \
            'the list stays in sync across tabs. The canonical "list of records" pattern.'
        end

        def content
          try_it
          the_row
          the_list
          broadcasting
          what_you_get
          keyed_lists
        end

        private

        def try_it
          DocsUI::Section('Try it') do
            md <<~MD
              This is a **real** reactive list rendered right here — not a
              screenshot. Add a row (Enter or the button), toggle it, rename it
              inline, or archive it. Each interaction POSTs to `/reactive/actions`,
              the server rebuilds the component from its signed token, runs the
              action, and re-renders in place — no Stimulus controller and no
              `.turbo_stream.erb` anywhere. Turn on the latency toggle to watch the
              optimistic toggle/hide and the `busy:` guard.
            MD
            render Views::Examples::LatencyToggle.new(delay_ms: 600)
            render Views::Examples::LiveExample.new(
              component: TodoListComponent.new,
              filename: 'app/components/todo_list_component.rb'
            )
          end
        end

        def the_row
          DocsUI::Section('One row (record-backed, all the actions)') do
            md <<~MD
              Each row is `TodoItemComponent` — record-backed via
              `reactive_record :todo`, so its identity is the Todo's GlobalID and
              the token re-finds the record server-side (never trusts client
              state). Its `#id` is `dom_id(@todo)`, the single source of truth for
              the row: the morph target for its own actions AND for broadcasts.

              - **`optimistic: { checked: :keep }`** on the toggle flips the
                checkbox the instant you click — without it the reactive
                controller's `preventDefault` would leave the box unticked until
                the morph arrives. `optimistic: { hide: true, to: :root }` on
                archive hides the row immediately; `reply.remove` then drops it, so
                it never flashes back. Hints are cosmetic and always reversible — a
                failed round trip replays the inverse.
              - **`reply.morph`** (rename) re-renders via Idiomorph, preserving the
                focused input + caret — a plain `replace` would tear the field out
                from under the typist. **`reply.remove`** (archive) drops the
                actor's own row with no doomed self re-render.
              - **`busy: "…"`** disables the archive button while the action
                is in flight, so a rapid double-click fires archive exactly once.
            MD
            DocsUI::Code(read_component('todo_item_component.rb'),
                         lexer: :ruby, filename: 'app/components/todo_item_component.rb')
          end
        end

        def the_list
          DocsUI::Section('The list + composer') do
            md <<~MD
              `TodoListComponent` renders one `TodoItemComponent` per row plus the
              composer. Its `add` action creates the Todo, **broadcasts the new
              row's component to every OTHER subscribed tab**, and re-renders self
              so the actor sees the row and the empty-state clears.

              - **`broadcast_to(..., append: todo, exclude: reactive_connection_id)`**
                is the load-bearing detail. An `append` *inserts* a child — it is not
                id-deduped the way a `replace`/`morph` of an existing element is.
                Without `exclude:`, the actor's own subscribed tab would receive the
                broadcast and append the row a **second** time, on top of the copy
                the self re-render already rendered.
              - **`busy: "Adding…"`** stops a rapid double-click on **Add**
                from creating two todos.
              - **`on_client(:click, js.toggle("#todo-tips"))`** on the Tips button
                shows/hides the hint client-side with no token, no POST — a
                zero-round-trip DOM op the one generic controller applies locally.
            MD
            DocsUI::Code(read_component('todo_list_component.rb'),
                         lexer: :ruby, filename: 'app/components/todo_list_component.rb')
          end
        end

        def broadcasting
          DocsUI::Section('Broadcasting: suppress the actor echo') do
            md <<~MD
              Every mutating action ends the same way: update the record,
              **broadcast to the other tabs, and reconcile the actor via the HTTP
              reply.** The one rule that keeps it correct is
              `exclude: reactive_connection_id` on the broadcast:

              - **`add` → `broadcast_to(..., append: todo)`** — an append inserts a
                child, so the actor MUST be excluded or the row double-applies
                (append is not id-deduped).
              - **`toggle` / `rename` → `broadcast_to(..., replace: todo)`** — a
                replace/morph is keyed by dom id, so idiomorph dedupes it for the
                actor even without `exclude:`. Passing `exclude:` anyway keeps every
                action on one consistent pattern and avoids a redundant echo.
              - **`archive` → `broadcast_to(..., remove: todo)`** — remove is
                idempotent, so a double remove is invisible; `exclude:` still spares
                the actor a redundant echo they already handled via `reply.remove`.
            MD
            DocsUI::Callout(:tip) do
              md <<~MD
                Treat `exclude: reactive_connection_id` as the default on **every**
                broadcast that pairs with an actor reply. It's mandatory for
                `append`/`prepend` and harmless-but-consistent for
                `replace`/`morph`/`remove`. See
                [Broadcasting & live updates](/docs/broadcasting).
              MD
            end
          end
        end

        def what_you_get
          DocsUI::Section('What you get') do
            md <<~MD
              - Toggle, rename, add, archive — all without a Stimulus controller or
                a `.turbo_stream.erb`.
              - **Optimistic delete + instant toggle** via
                `optimistic: { hide: true }` / `optimistic: { checked: :keep }` — the
                UI reacts in the same gesture, the morph reconciles from server
                truth, and a failure snaps it back.
              - **Enter-to-add and Enter-to-save** via
                `on(:add, event: "keydown.enter")` — Stimulus's native keyboard
                filter, no custom JavaScript.
              - **No double-submit:** `busy:` disables the Add / archive
                buttons while their action is in flight.
              - **Focus-preserving inline rename** via `reply.morph` (Idiomorph
                keeps the caret in the field), and a client-only tips toggle via
                `on_client` + `js` — zero round trip.
              - Every change broadcasts the affected **row** (not the whole list)
                with `exclude: reactive_connection_id`, so other tabs update with a
                minimal payload and the actor never doubles.
            MD
          end
        end

        def keyed_lists
          DocsUI::Section('Keyed lists & morphing') do
            md <<~MD
              Give each row a stable `id` (here `dom_id(@todo)`) so idiomorph can
              match rows across renders — that's what lets `reply.morph` preserve
              focus in the rename input and avoids re-creating unchanged rows.
              The morph keeps the focused field's in-progress value while
              writing the fresh server value as the new default (issue #338);
              every other field takes the server's value.
            MD
            DocsUI::Callout(:warning, title: 'Don’t render list items without a stable id') do
              md <<~MD
                Without a stable per-row id, idiomorph can't key the rows: focus is
                lost in the rename input and unchanged rows are needlessly
                re-created. `reply.morph` only preserves the caret when the row it
                morphs has a stable id to match against.
              MD
            end
          end
        end

        # Read a reactive component's own source off disk so the code shown on the
        # page can never drift from the component the demo renders.
        def read_component(basename)
          Rails.root.join('app/reactive_components', basename).read.strip
        end
      end
    end
  end
end
