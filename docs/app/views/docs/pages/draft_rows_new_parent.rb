# frozen_string_literal: true

# Zeitwerk resolves this compact reference through the directory-implied
# namespaces (app/views/docs/pages/ → Views::Docs::Pages), so there's no need
# for the 4-level nested-module ceremony.
module Views
  module Docs
    module Pages
      class DraftRowsNewParent < DocsUI::Page
        title 'Example: draft rows for a new parent'
        eyebrow 'Examples'
        description 'Build a "new parent + child rows" Rails form with reactive Phlex: add/remove line items ' \
                    'client-side before the parent exists, reconcile via accepts_nested_attributes_for'

        def lead
          'The "new order + line items" form: the user builds up child rows BEFORE ' \
            'the parent exists. An unsaved parent has no GlobalID to sign, so this ' \
            'pre-save window runs entirely client-side — zero round trips — and the ' \
            'real form submit creates parent + rows in ONE request.'
        end

        def content
          the_problem
          the_wiring
          one_row
          the_reconcile
          json_mode
          fill_then_add
          confirm_on_remove
          draft_actions
          notes
        end

        private

        def the_problem
          DocsUI::Section('Why this can’t be a reactive collection (yet)') do
            md <<~MD
              A [reactive collection](/docs/example-collections) assumes the parent
              the rows attach to already exists: the row actions re-derive it from a
              signed record identity, which needs a GlobalID — an `id`. A parent that
              is still a **draft** (`new_record?`) can't be signed, so the classic
              "new X" form (build line items, tasks, attachments; save everything at
              once) traditionally falls back to bespoke JavaScript: clone a `<tr>`,
              renumber indexes, serialize into the form on submit.

              `reactive_nested_*` is that pattern as a primitive, the `reactive_tags`
              posture: the rows are **form state**, add/remove run entirely
              client-side (no token, no POST — it works in a token-less
              `ClientBindings` component), and the surrounding **real form submit**
              posts standard Rails `parent[assoc_attributes][<index>][field]` names
              so `accepts_nested_attributes_for` reconciles in one create.
            MD
          end
        end

        def the_wiring
          DocsUI::Section('The wiring') do
            md <<~MD
              Three markers and two triggers, all keyed by the association name (so
              several collections can share one root):

              ```ruby
              class DraftOrderForm < ApplicationComponent
                include Phlex::Reactive::ClientBindings

                reactive_scope :order   # names post as order[line_items_attributes][…]

                def view_template
                  div(**reactive_root(id: 'draft_order_form')) do
                    form(action: orders_path, method: 'post', data: { turbo: 'false' }) do
                      input(**reactive_field(:total, type: 'number', value: '0'))

                      div(**reactive_nested_list(:line_items)) { }             # rows land here
                      template(**reactive_nested_template(:line_items)) { row_fields }
                      button(**reactive_nested_add(:line_items)) { 'Add item' }

                      button(type: 'submit') { 'Create order' }
                    end
                  end
                end
              end
              ```

              Clicking **add** clones the `<template>` row and swaps every `NEW_ROW`
              placeholder in the clone's `name`/`id`/`for` attributes for a fresh
              unique index — clock-seeded and strictly monotonic, so server-rendered
              `0..n` indexes and a same-millisecond double click can never collide —
              then focuses the new row's first field. **Remove** deletes a draft row
              from the DOM; on a row carrying a hidden `[_destroy]` input (an edit
              form's persisted row) it marks it `"1"` and hides the row instead, so
              Rails destroys it on save.
            MD
          end
        end

        def one_row
          DocsUI::Section('One row, authored once') do
            md <<~MD
              `nested_field_name` builds the Rails nested-attributes wire name. With
              no index it renders the template placeholder; with `index:` it renders
              a real row — so the SAME method serves the template prototype, an edit
              form's persisted rows, and (after the parent is saved) the
              server-rendered collection:

              ```ruby
              # The default is the template form (NEW_ROW placeholder names);
              # pass index: to server-render an edit form's persisted rows.
              def row_fields(index: nil)
                kwargs = index.nil? ? {} : { index: }
                div(**reactive_nested_row) do
                  input(name: nested_field_name(:line_items, :quantity, **kwargs), type: 'number')
                  input(name: nested_field_name(:line_items, :price, **kwargs), type: 'number')
                  button(**reactive_nested_remove) { '×' }
                end
              end
              ```

              Under `reactive_scope :order` the emitted names are
              `order[line_items_attributes][NEW_ROW][quantity]` (template) and
              `order[line_items_attributes][3][quantity]` (a server-rendered row) —
              the scope wraps the `line_items_attributes` base, never the whole
              bracketed path.

              When the parent prefix is **per-instance** — a form builder's
              object name, possibly itself bracketed (`"user[profile]"`) — pass
              `scope:` per call instead: it is used verbatim and wins over the
              class-level scope
              (`nested_field_name(:line_items, :quantity, scope: 'order')`).
            MD
          end
        end

        def the_reconcile
          DocsUI::Section('The reconcile — plain Rails') do
            md <<~MD
              Nothing bespoke on the server. The submit is one POST carrying the
              parent's fields and every surviving row's indexed group:

              ```ruby
              class Order < ApplicationRecord
                has_many :line_items, dependent: :destroy
                accepts_nested_attributes_for :line_items, allow_destroy: true
              end

              # The controller create:
              Order.create!(params.require(:order).permit(:total,
                line_items_attributes: %i[id quantity price _destroy]))
              ```

              A removed draft row simply isn't in the POST; a `_destroy`-marked
              persisted row rides along as `_destroy=1` and Rails deletes it.
            MD
          end
        end

        def json_mode
          DocsUI::Section('JSON mode — one hidden field instead of nested attributes') do
            md <<~MD
              Not every app persists a "new parent + child rows" form through
              `accepts_nested_attributes_for`. A common alternative serializes
              the rows into a single hidden field and `JSON.parse`s it in the
              controller. If that is your existing persistence path, opt the
              list into `as: :json` and **keep the controller exactly as it is**
              — the primitive adapts to your wire, not the other way around:

              ```ruby
              # rows land here AND sync into the hidden field below:
              div(**reactive_nested_list(:line_items, as: :json)) { }
              # the client keeps this in sync (seed "[]" so an empty submit posts one):
              input(type: 'hidden', **reactive_field(:line_items), value: '[]')

              template(**reactive_nested_template(:line_items)) { row_fields }
              button(**reactive_nested_add(:line_items)) { 'Add item' }

              # Form-builder escape hatch: name the hidden field VERBATIM
              # (never re-scoped) when the wire name is computed per instance:
              div(**reactive_nested_list(:line_items, as: :json, name: 'order[line_items]')) { }
              ```

              The row markup is unchanged — the same `<template>`, the same
              `nested_field_name`, the same add/remove triggers. In JSON mode the
              generic controller mirrors the surviving rows into that one hidden
              field as a JSON array on every add / remove / keystroke (the
              set-value + dispatch contract, so dirty tracking and compute still
              see it), **inferring each JSON key from the trailing bracket
              segment** of a row input's name — `order[line_items_attributes][3][quantity]`
              → `"quantity"`. A removed row simply leaves the array (JSON has no
              `_destroy` marker — an absent row *is* the removal).

              The reconcile is your own hand-rolled parse, no nested attributes:

              ```ruby
              rows = JSON.parse(params.require(:order).permit(:line_items)[:line_items].presence || '[]')
              order = Order.create!(total: params[:order][:total])
              rows.each { order.line_items.create!(quantity: it['quantity'], price: it['price']) }
              ```
            MD

            DocsUI::Callout(:note) do
              md <<~MD
                The per-row `…_attributes[i][field]` names still render (that is
                what the key is inferred from), so a submit posts them alongside
                the JSON field. A controller that permits only the JSON param
                ignores the extras — the hidden field is the single source of
                truth. Want a byte-clean POST? Drop the row-input names; then the
                keys must be declared, which `as: :json` (infer-from-names)
                deliberately doesn't require.
              MD
            end
          end
        end

        def fill_then_add
          DocsUI::Section('Fill-then-add — add controls outside the row') do
            md <<~MD
              The default `reactive_nested_add` is **inline-edit**: it clones the
              template and focuses the new row's first field, so you type INTO
              the row. But a very common form shape puts the add controls
              OUTSIDE the row — a preset `<select>`, a typeahead, plain inputs —
              and clicking **Add** *snapshots* those values into a new row, then
              clears the controls for the next entry.

              Pass `from:` (a map of row field → source-control selector) and
              optionally `clear:`:

              ```ruby
              input(id: 'item-name', type: 'text')      # the add controls, OUTSIDE the row
              input(id: 'item-qty',  type: 'number')

              button(**reactive_nested_add(:line_items,
                from: { name: '#item-name', quantity: '#item-qty' },
                clear: true)) { 'Add item' }
              ```

              On click the client clones the template, fills each cloned-row
              field from its source control's current value — matching the field
              by the **same** trailing bracket-segment key inference JSON mode
              uses — keeps focus on the sources (so you keep entering the next
              item; it does *not* steal focus into the row), and with `clear:
              true` resets the sources (each via the set-value + dispatch
              contract, so dirty tracking and compute observe the reset).

              It composes with **both** wire modes: the seeded values ride the
              renumbered `_attributes` names on submit (`:attributes`), and the
              end-of-add JSON sync serializes them (`as: :json`) — no extra
              wiring either way.
            MD

            DocsUI::Callout(:note) do
              md <<~MD
                `from:` values are raw CSS selectors resolved WITHIN this
                reactive root (issue #15 ownership) — the escape-hatch posture of
                `reactive_filter`/`reactive_tags`, since the sources are your own
                markup, not `reactive_field` bindings. A selector that resolves
                nothing, or a row-field key with no matching cloned field, is
                silently skipped (the row still adds) — a half-mapped binding
                never throws on click.
              MD
            end
          end
        end

        # The %{field} tokens in the confirm examples below are the CLIENT's
        # interpolation syntax (the reactive runtime parses them on remove), not
        # Ruby format strings — Style/FormatStringToken's annotated-token
        # preference doesn't apply to documentation of client-side markup.
        # rubocop:disable-next Style/FormatStringToken
        def confirm_on_remove
          DocsUI::Section('Confirm before removing a row') do
            md <<~'MD'
              Removing a row can be a real loss — a line item with an entered
              amount, not just an empty new row. `reactive_nested_remove` accepts
              the **same** `confirm:` the other triggers (`on`/`on_client`) do,
              gated behind the same overridable `confirmResolver` (the
              styled-modal seam) — so a "sure?" needs no bespoke JS:

              ```ruby
              button(**reactive_nested_remove(confirm: 'Really delete this row?')) { '×' }
              ```

              On click the client runs the confirm; on **accept** it does the
              existing remove (a draft row leaves the DOM; a persisted row is
              `_destroy`-marked + hidden) and the existing JSON/attributes
              re-sync; on **cancel** nothing happens. It works in both wire modes.

              **Server-rendered rows** get per-row detail for free — the confirm
              is a per-render string, so a persisted row just renders its own (as
              with `on(:destroy, confirm:)`):

              ```ruby
              button(**reactive_nested_remove(
                confirm: "Really delete #{row.name} (#{row.amount})?")) { '×' }
              ```

              **Client-added rows use a `%{field}` placeholder (#222).** A row you
              add in the browser is a `cloneNode` of the `<template>`, so it can
              only carry the template's confirm string — and the template row has
              no values yet. Interpolate at the client instead: put a
              `%{field_key}` placeholder in the message, and on remove the client
              substitutes **that row's own live field values** (keyed by the same
              trailing-bracket inference `as: :json` uses). The message reflects
              the row the user actually built, and a later edit is reflected too
              (it resolves at click time, not clone time):

              ```ruby
              # The template row is value-less, so this renders "%{name}"/"%{amount}"
              # literally; the client fills them from the ADDED row on remove.
              td { input(name: nested_field_name(:line_items, :name)) }
              td { input(name: nested_field_name(:line_items, :amount), type: 'number') }
              button(**reactive_nested_remove(
                confirm: "Delete '%{name}' (%{amount})?")) { '×' }
              # a row the user filled with "Widget"/42 prompts: Delete 'Widget' (42)?
              ```

              A `%{key}` with no matching row field is left as its literal text
              (visible and debuggable, never a silent blank). The placeholder
              works in the conditional Hash's `message:` too. Interpolation
              applies to `reactive_nested_remove` confirms only — `on`/`on_client`
              confirms never substitute — so if a remove confirm needs a
              **literal** `%{word}` where `word` also happens to be a field on the
              row, reword it (there is no escape); this only bites text that
              deliberately contains a field name in braces.

              It also composes with the conditional-confirm Hash form — prompt
              only when a condition matches, for parity with `on`/`on_client`:

              ```ruby
              # Only ask if the row still has a value; a blank draft row goes quietly.
              button(**reactive_nested_remove(
                confirm: { when: { amount: 1.. }, message: 'Remove %{name}?' })) { '×' }
              ```
            MD
          end
        end

        def draft_actions
          DocsUI::Section('Bonus: real server actions on a draft parent') do
            md <<~MD
              Independent of the rows, a draft parent can now round-trip **real
              server actions** too. An unsaved record signs a gid-less `{c, state}`
              token (the identity layer already omitted the GlobalID), and the action
              endpoint rebuilds the component through the record kwarg's
              **initialize default**, with the declared `reactive_state` riding the
              token:

              ```ruby
              class OrderComponent < ApplicationComponent
                include Phlex::Reactive::Component

                reactive_record :order
                reactive_state :total, :allowance, :cash, :leasing
                action :rebalance, params: { allowance: :integer, cash: :integer,
                                             leasing: :integer, total: :integer }

                # The default is what a DRAFT token rebuilds through — a component
                # whose initialize REQUIRES the kwarg raises a guided error instead.
                def initialize(order: Order.new, total: nil, allowance: nil, cash: nil, leasing: nil)
                  # …
                end
              end
              ```

              The action runs against the rebuilt draft (guard your writes with
              `@order.persisted?`), re-renders, and the fresh token — still gid-less —
              rides the reply.
            MD
          end
        end

        def notes
          DocsUI::Section('Boundaries') do
            md <<~MD
              - **The DOM is the single source of truth for unsent draft rows.** A
                server re-render of the root REPLACES them — keep replace-shaped
                actions out of a root holding unsent rows.
              - **Nesting a collection inside another's template is unsupported** —
                the placeholder swap would hit both (the same limitation as every
                template-clone implementation).
              - Once the parent is saved, the persisted flow takes over: the same row
                markup renders with real indexes, or the list graduates to a
                [reactive collection](/docs/example-collections)
                (`reactive_collection` + `reply.append` / `reply.remove`).
            MD

            DocsUI::Callout(:tip) do
              md <<~MD
                Emit `data-turbo` as the STRING `"false"` on the form if you want the
                native (non-Turbo) submit — Phlex omits a Ruby `false` attribute
                entirely, and Turbo then intercepts the POST and requires a redirect
                response.
              MD
            end
          end
        end
      end
    end
  end
end
