# frozen_string_literal: true

module Views
  module Docs
    module Pages
      # The reference home for the `on(...)` API — declaration, the param schema,
      # event triggers, timing modifiers, and the page-level modifiers from #80.
      # The param-types table mirrors the README (:355–385) so there is one source
      # of truth for the names and semantics.
      class ActionsEvents < DocsUI::Page
        title 'Actions & events'
        eyebrow 'Guide'
        description 'Bind DOM events to default-deny reactive Phlex actions in Rails: declare on(...) handlers, coerce input via a param schema, add keyboard and timing modifiers'

        def lead
          'How a DOM event becomes a server action: `action` declares what the ' \
            'client may invoke, `on(...)` wires an element to it, a param schema ' \
            'coerces the input, and event/timing modifiers cover the page-level ' \
            'patterns that would otherwise need a hand-written Stimulus controller.'
        end

        def content
          declaring
          param_schema
          custom_types
          keyboard
          timing
          modifiers
          reserved
          client_only
        end

        private

        def declaring
          DocsUI::Section('Declaring an action, binding an event') do
            md <<~MD
              A reactive action is a two-step contract. `action :name` on the class
              declares the method the client may invoke — **default-deny**, so a
              public method with no `action` line is unreachable. `on(:name)` on an
              element wires a DOM event to that action: it emits the signed
              `data-reactive-*` attributes the one generic Stimulus controller reads.

              ```ruby
              class Counter < ApplicationComponent
                include Phlex::Reactive::Component

                reactive_record :counter
                action :increment            # declared → invokable
                action :decrement

                def increment = @counter.increment!(:value)
                def decrement = @counter.decrement!(:value)

                def view_template
                  div(**reactive_root) do
                    button(**on(:decrement)) { "−" }
                    span { @counter.value }
                    button(**on(:increment)) { "+" }
                  end
                end
              end
              ```

              `on(:action, event: "click")` defaults to a click and adds
              `type="button"` (so a bare button inside a `<form>` can't submit it).
              The event flows **client → endpoint → action → re-render**: the click
              POSTs the signed token, the endpoint verifies it and runs the declared
              method, and the component re-renders into its own `#id`. No routes, no
              partial, no hand-picked Turbo target.
            MD

            DocsUI::Callout(:note, title: 'Combining on(...) with other attributes') do
              md <<~MD
                `on(...)` returns a `data:` hash. Merging it with another `data:`/
                `class:` with a bare `**` **clobbers** the `data-action` the
                descriptor rides on. Use Phlex's `mix` to deep-merge:

                ```ruby
                button(**mix(on(:increment), class: "btn", data: { testid: "inc" })) { "+" }
                ```
              MD
            end
          end
        end

        def param_schema
          DocsUI::Section('Passing input — the param schema') do
            md <<~MD
              An action that takes input declares its params. Only declared keys
              reach the method, each **coerced to its declared type**; anything not
              in the schema is dropped before your method runs (no raw mass
              assignment). The schema is **compiled once at declaration** — a typo'd
              type symbol raises `Phlex::Reactive::UnknownParamType` at class load,
              not silently at click time.

              ```ruby
              action :rename, params: { title: :string }
              def rename(title:)
                authorize! @todo, :update?      # the signature is not authorization
                @todo.update!(title:)
              end
              ```

              | Type | Coercion | Dropped when |
              |---|---|---|
              | `:string` | the default; used raw | — |
              | `:integer` | `Integer(value)` | non-numeric |
              | `:float` | `Float(value)` | non-numeric |
              | `:boolean` | truthy string → `true`/`false` | — |
              | `:date` | ISO8601 → `Date` | won't parse |
              | `:datetime` | ISO8601 → `Time` | won't parse |
              | `:decimal` | `BigDecimal(value)` | non-numeric |
              | `:file` | `ActionDispatch::Http::UploadedFile`, untouched | a non-file value |

              **Drop, don't fabricate.** A value that won't coerce is dropped, so the
              method receives its keyword default — never a fabricated zero or a
              coerced-to-string surprise. Give every declared param a default
              (`def rename(title: nil)`) so a dropped value has somewhere to land.

              Nested and array params compose. A `params: { invoice: { date: :string } }`
              matches bracketed field names (`invoice[date]`) after the endpoint
              expands the brackets — so the schema must mirror the field **names**,
              not the conceptual params. A flat `{ date: :string }` against
              `invoice[date]` inputs matches nothing and the value is silently
              dropped.

              **Checkbox groups.** Controls sharing a name that ends in `[]` are
              collected as an **array of the chosen values**: a ticked box
              contributes its `value`, an unticked one nothing, a `<select
              multiple>` its selected options. Declare it as an array type.

              ```ruby
              action :save, params: { features: [:string] }
              # <input type="checkbox" name="features[]" value="news">
              ```

              Nothing ticked is an **empty array**, not a missing key, so an action
              can tell a cleared group from one that never rendered. That holds
              over a form body too, which the client uses as soon as a file input
              holds a file: an empty array can't be written there, so the client
              names the cleared group in `empty_groups[]` and the endpoint sets it
              to `[]`. This works for params declared as an array at the top
              level, by their plain name or with the component's
              `reactive_scope`. A group declared one level down keeps its keyword
              default. The README has the details.

              Three shapes keep their own meaning: a lone checkbox without `[]`
              stays the yes/no boolean, a radio group keeps its single checked
              value with or without `[]`, and a hidden input sharing a name with a
              checkbox is that box's **companion** — Rails' `check_box` emits one
              carrying the `unchecked_value`, `"0"` by default — and contributes
              nothing. A hidden input *without* a same-named checkbox is an
              ordinary value, the usual shape for a list JS maintains.
            MD

            DocsUI::Callout(:tip, title: 'Files & multipart') do
              md <<~MD
                Declare `:file` (or `[:file]` for multiple) to accept an upload in a
                reactive action. When the root holds a populated `<input type="file">`,
                the client sends the action as multipart `FormData` instead of JSON —
                same bracket-expanded field shape, so both bodies coerce identically.
                See the [uploads example](/docs/example-uploads) for the full
                walkthrough.
              MD
            end
          end
        end

        def custom_types
          DocsUI::Section('Custom param types (Phlex::Reactive.param_type)') do
            md <<~'MD'
              Register your own type in an initializer. The block receives the raw
              client value and returns the coerced value, or
              `Phlex::Reactive::ParamSchema::DROP` to reject it (the keyword default
              then applies — the same drop-don't-fabricate contract as the built-ins).

              ```ruby
              # config/initializers/phlex_reactive.rb
              Phlex::Reactive.param_type(:money) do |value|
                if /\A\d+(\.\d{1,2})?\z/.match?(value.to_s)
                  BigDecimal(value)
                else
                  Phlex::Reactive::ParamSchema::DROP
                end
              end

              # then, in any component:
              action :charge, params: { amount: :money }
              def charge(amount:) = @invoice.charge!(amount)   # a BigDecimal, or unset
              ```

              A schema referencing a registered type is validated at declaration like
              any built-in.
            MD

            DocsUI::Callout(:warning, title: 'Register during boot only') do
              md <<~MD
                The type registry is **frozen after initialization**. A runtime
                `param_type` call raises — register every custom type from an
                initializer, never lazily from a component.
              MD
            end
          end
        end

        def keyboard
          DocsUI::Section('Keyboard triggers (event:)') do
            md <<~MD
              `event:` is interpolated straight into the Stimulus action descriptor,
              so any Stimulus event string works — including its native **keyboard
              filters**. Pass `event: "keydown.enter"` to fire only on Enter,
              `event: "keydown.esc"` for Escape — the classic "Enter adds the row",
              "Escape cancels the edit" interactions, with no `event.key` check of
              your own.

              ```ruby
              # Enter in the composer adds the todo (same action as the Add button).
              input(**mix(on(:add, event: "keydown.enter"), name: "title", placeholder: "New todo…"))

              # Inline editor: Enter saves; a separate control cancels on Escape.
              input(**mix(on(:save, event: "keydown.enter"), name: "title", value: @todo.title))
              button(**on(:cancel, event: "keydown.esc")) { "Cancel" }
              ```

              The filter tokens are Stimulus's own (`enter`, `esc`, `space`, `up`,
              `down`, a bare letter, …). A keyboard trigger isn't a click, so it gets
              **no** forced `type="button"`. Folding the key into `event:` keeps `key`
              free as an ordinary action-param name.
            MD

            DocsUI::Callout(:note, title: 'One action per element') do
              md <<~MD
                Each trigger element carries a **single** reactive action, so you
                can't put `on(:save, event: "keydown.enter")` and
                `on(:cancel, event: "keydown.esc")` on the same input — the second
                overwrites the first. Bind each key trigger to its own element.
              MD
            end
          end
        end

        def timing
          DocsUI::Section('Timing — debounce: and throttle:') do
            md <<~MD
              Two mutually-exclusive rate limiters shape how rapid events reach the
              server. Passing both raises `ArgumentError`.

              - **`debounce: 300` (trailing-edge)** coalesces rapid events into one
                round trip fired after the quiet period — live-as-you-type without a
                POST per keystroke. A blur flushes a pending dispatch so the last
                edit is never dropped.
              - **`throttle: 250` (leading-edge)** fires the first event immediately,
                then drops further events until the window elapses — for a hot
                trigger like `scroll` or `mousemove`.

              ```ruby
              # Recompute a total live as the user types, without hammering the endpoint.
              input(**mix(on(:update, event: "input", debounce: 300), name: "quantity", value: @item.quantity))
              ```
            MD
          end
        end

        def modifiers
          DocsUI::Section('Page-level modifiers — window:, outside:, once:') do
            md <<~MD
              Three modifiers (issue #80) cover the page-level trigger patterns that
              otherwise need a hand-written Stimulus controller:

              - **`window: true`** binds the trigger to the window (Stimulus's native
                `@window`) for page-level events like `scroll`/`resize`. A
                window-bound trigger is **never `preventDefault`-ed** — a mounted
                dropdown must not kill link clicks elsewhere — and skips the forced
                `type="button"`.
              - **`outside: true`** fires the action only for events whose target is
                **outside** this component's root — the close-a-dropdown-on-outside-click
                pattern. An event inside the root is a complete client-side no-op.
                Implies `window: true`.
              - **`once: true`** fires at most once, then unbinds (Stimulus's
                `:once`).

              ```ruby
              # A dropdown that closes itself on any click outside — no Stimulus controller.
              div(**mix(reactive_root, on(:close_menu, outside: true))) do
                button(**on(:toggle_menu)) { "Menu" }
                ul { menu_items } if @open
              end

              # Throttled page-scroll tracking.
              div(**mix(reactive_root, on(:track, event: "scroll", window: true, throttle: 500)))
              ```
            MD
          end
        end

        def reserved
          DocsUI::Section('Reserved keyword names') do
            md <<~MD
              These keywords on `on(...)` are **reserved** — they configure the
              trigger and are no longer usable as free action-param names. Everything
              **not** on this list flows through as an action param (so
              `on(:switch, key: "pgbus")` still passes `key` as a param):

              | Keyword | Purpose |
              |---|---|
              | `event:` | the DOM event / Stimulus keyboard filter (`"click"`, `"keydown.enter"`, …) |
              | `debounce:` | trailing-edge coalescing (ms) |
              | `throttle:` | leading-edge rate limit (ms) |
              | `window:` | bind to the window |
              | `outside:` | fire only outside the root (implies `window:`) |
              | `once:` | fire at most once |
              | `confirm:` | gate behind a confirmation dialog — a String (always), or a Hash (conditional, #179) |
              | `optimistic:` | reversible cosmetic hint applied before the round trip |
              | `busy:` | declarative pending state on the trigger |

              A misspelled action surfaces early: with `Phlex::Reactive.verbose_errors`
              on (the default in development and test), `on(:typo)` **raises at render
              time** listing the declared actions, instead of an opaque 403 on click.
              Production keeps the permissive emit so a stale page after a deploy that
              removed an action never 500s on render.

              Combobox keyboard navigation is no longer an `on(...)` keyword — it's
              the standalone `reactive_listnav` helper, composed via `mix`, e.g.
              `mix(on(:search, event: "input"), reactive_listnav)`.

              **Conditional confirm (#179).** `confirm:` also takes a Hash to warn
              *only when the field values look suspect* — soft-validation before submit,
              evaluated client-side over the same collected fields, no bespoke handler:

              ```ruby
              # Declarative — reuses reactive_show's conditions language (scalar = equals,
              # Range = threshold, Array = membership). Prompts only when it MATCHES.
              on(:save, confirm: { when: { total: 0 }, message: "Total is 0 — continue?" })
              on(:save, confirm: { when: { qty: 100.. }, message: "Large order — sure?" })

              # Named predicate — for multi-field logic. Register a pure function at boot
              # (the setComputeReducer twin); it runs over the collected fields.
              #   setConfirmPredicate("end_before_start", ({ starts_at, ends_at }) => ends_at < starts_at)
              on(:save, confirm: { predicate: "end_before_start", message: "End precedes start — continue?" })
              ```

              The Hash form works on `on_client(...)` too. It is **soft-validation UX, not
              authorization** — a user can bypass any client predicate and the action still
              hits the endpoint's real `authorize!` / default-deny. Never let a predicate
              stand in for a server-side check.
            MD
          end
        end

        def client_only
          DocsUI::Section('on_client — the same modifiers, zero round trips') do
            md <<~MD
              `on_client(:event, ops)` binds a DOM event to a chain of declared DOM
              operations the controller applies **locally** — no token, no params, no
              POST, ever. It's the zero-round-trip sibling of `on(...)`, for purely
              presentational state (tabs, a dropdown, an accordion).

              ```ruby
              div(**mix(reactive_root, on_client(:click, js.hide("#menu"), outside: true))) do
                button(**on_client(:click, js.show("#menu"))) { "Menu" }
                div(id: "menu", hidden: true) { menu_items }
              end
              ```

              `window:`, `once:`, and `outside:` compose **exactly** as they do on
              `on(...)`: the menu above closes on any outside click, and the
              window-bound trigger never `preventDefault`s. Reach for `on_client` when
              the interaction is presentational; reach for a signed `action` (a token
              + POST) only when the server must **decide** or **persist** something.
              See the [client-only ops example](/docs/example-client-ops) for the live
              version.

              The vocabulary includes `submit` (#226): `on_client(:change,
              js.submit("form"))` on a select is the one-line autosubmit filter —
              `requestSubmit()` fires a real submit event, so a native/Turbo form
              navigates normally and an `on(:save, event: "submit")` interception
              turns it into a signed action instead. Actor-only like focus: refused
              in broadcasts.

              And `paste_into` (#228): `on_client(:click,
              js.paste_into("[name=code]"))` reads the clipboard into a field on the
              user's gesture and feeds it through the normal `input` pipeline — the
              explicit paste affordance for a field whose real input is visually
              hidden (an OTP cell UI). Author the trigger `hidden` and the controller
              reveals it only where the clipboard API exists. Actor-only too.
            MD
          end
        end
      end
    end
  end
end
