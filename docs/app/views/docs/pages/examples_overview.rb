# frozen_string_literal: true

module Views
  module Docs
    module Pages
      class ExamplesOverview < DocsUI::Page
        title 'Examples'
        eyebrow 'Examples'
        description 'Browse live, copy-pasteable reactive Phlex examples for Rails — counters, cross-tab chat, todo lists, broadcasts, optimistic UI, and the flagship team inbox'

        def lead
          'Concrete, copy-pasteable examples covering the common patterns. ' \
            'Each is a complete, working feature — with the live reactive ' \
            'component rendered on its page and its source read straight off the ' \
            'file, so the demo and the code can never drift.'
        end

        # One section only — an overview index stays scannable, and the auto-TOC
        # deliberately hides on a page with too few sections (see the system
        # spec). The two tables (the examples + the by-feature map) live under the
        # single heading so no TOC is triggered.
        def content
          DocsUI::Section('The examples') do
            md <<~MD
              Each page below renders its **real** reactive component inline — click
              it, it round-trips. They build from the smallest reactive component up
              to record-backed actions, live broadcasts, declared-once collections,
              and the two flagships — the inbox and the kanban board — that compose
              everything.

              | Example | What it shows |
              |---|---|
              | [Counter](/docs/example-counter) | State-backed — the smallest reactive component. Click → server → re-render, no DB row. |
              | [Payment split](/docs/example-payment-split) | Nested bracketed params, auto-collected siblings, and a live `reactive_compute` + `reactive_text` preview that paints before the debounced save. |
              | [Cross-tab chat](/docs/example-chat) | Record-backed action **and broadcast** → live cross-tab sync, zero JS. |
              | [Live todo list](/docs/example-todo-list) | Per-row record-backed components: add / toggle / rename / archive, optimistic toggle + delete, Enter-to-add, morph-in-place, broadcast on change. |
              | [Inline edit + dirty tracking](/docs/example-inline-edit) | Show ↔ edit (Enter saves, Escape cancels) plus an “Unsaved” badge + leave-guard with zero shipped state. |
              | [Notifications / badges](/docs/example-notifications) | Pure broadcast — a background event pushes a live re-render, plus a `broadcast_to(js:)` cross-tab pulse. |
              | [Reactive collections](/docs/example-collections) | Add / remove rows + a running count + an empty state, declared **once** with `reactive_collection`, optimistic dismiss + a self-dismissing flash. |
              | [File uploads & custom types](/docs/example-uploads) | `:file` / `[:file]` params (multipart `FormData`), a nested-hash param alongside the file (#39), and a custom `Phlex::Reactive.param_type`. Code-first — no live demo. |
              | [Loading states](/docs/example-loading-states) | `busy:` + `busy_on` + the always-on `aria-busy`, with a latency toggle to make the pending window visible. |
              | [Client-only ops](/docs/example-client-ops) | `on_client` tabs / outside-close menu / accessible drawer — zero fetches, zero custom JS. |
              | [Failure surface](/docs/example-failure) | `error_flash` + `data-reactive-error` + `dismiss_after:` — what an adopter gets for free when an action fails. |
              | [Team inbox (flagship)](/docs/example-team-inbox) | The whole toolkit in one UI: collection rows, optimistic archive that **reverts on failure**, cross-tab broadcast, an `on_client` kebab, and error flashes. |
              | [Project board (flagship)](/docs/example-project-board) | The kanban: cards move across lanes with **enter/exit effects** (per-visitor style picker incl. `random`), live count badges in every tab via `broadcast_to(js:)`, nested reactive rows with inline rename, confirm-gated archive. |

              **Every headline feature now has a live page.** Pick a capability:

              | Feature | Where it's shown (live) |
              |---|---|
              | **Client-only ops** — `on_client` + `js` (`show`/`hide`/`toggle`, `set_attr`/`toggle_attr`, `focus`, `text`, `dispatch`, `submit`, `paste_into`, `check_group`, transitions): zero round trips | [Client-only ops](/docs/example-client-ops), [Todo list](/docs/example-todo-list), [Team inbox](/docs/example-team-inbox) |
              | **Client-side computes** — `reactive_compute` + `reactive_text` (a live preview / char counter that paints with no round trip) | [Payment split](/docs/example-payment-split) |
              | **Declarative loading states** — `busy:` / `busy_on` (+ the always-on `aria-busy` / `data-reactive-busy`) | [Loading states](/docs/example-loading-states), [Todo list](/docs/example-todo-list), [Collections](/docs/example-collections), [Team inbox](/docs/example-team-inbox) |
              | **Dirty-field tracking** — `reactive_dirty` / `warn_unsaved:` / `only:` (enable Save only on change; warn before leaving) | [Inline edit](/docs/example-inline-edit) |
              | **Optimistic visual hints** — `optimistic:` (flip a checkbox / hide a row instantly; revert on failure) | [Todo list](/docs/example-todo-list), [Collections](/docs/example-collections), [Team inbox](/docs/example-team-inbox) |
              | **Keyboard triggers** — `event: "keydown.enter"` / `"keydown.esc"` (Enter-to-add, Escape-to-cancel) | [Todo list](/docs/example-todo-list), [Inline edit](/docs/example-inline-edit) |
              | **Debounced / morph editing** — `debounce:` live-as-you-type + `reply.morph` to keep the caret | [Payment split](/docs/example-payment-split), [Inline edit](/docs/example-inline-edit) |
              | **Effects** — `reactive_effects` enter/exit/update + per-call `effect:` (incl. `random`) — see the [Effects guide](/docs/effects) | [Project board](/docs/example-project-board) |
              | **Live broadcasts** — `broadcast_to(replace:)` / `broadcast_to(append:)` / `broadcast_to(js:)` → cross-tab sync | [Chat](/docs/example-chat), [Notifications](/docs/example-notifications), [Todo list](/docs/example-todo-list), [Team inbox](/docs/example-team-inbox), [Project board](/docs/example-project-board) |
              | **Failure surface** — `error_flash` / `data-reactive-error` / `dismiss_after:` / timeout + offline | [Failure surface](/docs/example-failure), [Team inbox](/docs/example-team-inbox) |
              | **Combobox keyboard navigation** — `reactive_listnav` (Arrow keys move a client highlight, Enter picks), composed via `mix` | [Searchable combobox demo](/demos/searchable-combobox) |
              | **File uploads & custom param types** — `:file` / `[:file]` (multipart `FormData`), `Phlex::Reactive.param_type` | [File uploads & custom types](/docs/example-uploads) (code-first) |
            MD

            DocsUI::Callout(:note) do
              md <<~MD
                **File uploads** (`:file` / `[:file]` params, multipart `FormData`)
                and **custom param types** (`Phlex::Reactive.param_type`) have a
                dedicated [code-first walkthrough](/docs/example-uploads) — no live
                demo, because a public upload endpoint is a storage/abuse surface.
                The [payment split](/docs/example-payment-split) is the closest live
                cousin: the nested-params / auto-collected sibling-fields example that
                a `FormData` upload extends.
              MD
            end
          end
        end
      end
    end
  end
end
