# frozen_string_literal: true

module Views
  module Docs
    module Pages
      class ExampleClientOps < DocsUI::Page
        title 'Example: client-only ops'
        eyebrow 'Examples'
        description 'Build tabs, outside-close menus, and accessible drawers with on_client — phlex-reactive runs a whitelist of local DOM ops, zero round trips, no custom JS'

        def lead
          'Some interactions never need the server — tabs, a menu that closes on an ' \
            'outside click, an accessible drawer with a transition + focus. `on_client` ' \
            'runs a whitelist of DOM ops locally, with ZERO round trips and ZERO ' \
            'custom JavaScript.'
        end

        def content
          try_it
          how
          disclosure_menu
          ops
          value_conditional
          bulk_selection
          client_drafts
          when_to_use
        end

        private

        def try_it
          DocsUI::Section('Try it — nothing here hits the server') do
            md <<~MD
              Switch tabs, open the menu (then click anywhere outside to close it),
              open the drawer (it fades in and focus lands on its first button).
              Every one of these is a client op — **no token, no POST, ever**. Open
              the network tab: you will see nothing. The component declares **no
              actions** at all.
            MD
            render Views::Examples::LiveExample.new(
              component: ClientTabsComponent.new,
              filename: 'app/components/client_tabs_component.rb'
            )
          end
        end

        def how
          DocsUI::Section('How it works') do
            md <<~MD
              `on_client(:click, ops)` binds a chain of DOM ops to an event and runs
              them locally through the one generic reactive controller. The ops are a
              **frozen whitelist** — `show`/`hide`/`toggle`, `add_class`/
              `remove_class`/`toggle_class`, `set_attr`/`toggle_attr`/`remove_attr`
              (`toggle_attr` also flips between two values, and `show`/`hide`/`toggle`
              take `expanded:` to keep a trigger's `aria-expanded` in sync — #271),
              `focus`/`focus_first`, `text`, `dispatch`, `submit`, `paste_into` —
              each a local DOM mutation, with two deliberate exceptions. `submit`
              hands the form to its own native/intercepted submit path — the form
              may POST or navigate from there, but that is the form's contract,
              not the op's. `paste_into` (#228) **reads** the clipboard, behind
              the browser's own gesture and permission gates, and still only
              writes locally. Everything else sends nothing and reads nothing
              back.

              - **Tabs:** `js.hide(".ct-panel").show("#ct-panel-1")` plus class ops on
                the tab buttons — the "I had to write a Stimulus controller" case, now
                one line.
              - **Outside-close menu:** `on_client(:click, js.hide("#ct-menu"),
                outside: true)` on the **root** fires on any click *outside* the menu.
                A client op costs nothing per stray page click (unlike a server action).
              - **Accessible drawer:** `js.toggle("#ct-drawer", transition: { during:, from:, to: })`
                animates it, `set_attr(:root, "aria-expanded", "true")` updates the
                trigger, and `focus_first("#ct-drawer")` moves focus to the first
                control inside — the exact accessible-disclosure pattern, one chain.
            MD
          end
        end

        def disclosure_menu
          DocsUI::Section('Accessible disclosure menu') do
            md <<~MD
              The WAI-ARIA *menu button* pattern, still with **no actions and no
              custom JavaScript** (#271). Click the trigger, or focus it and press
              Arrow Down: the menu opens and focus lands on the first item. Arrow
              Up/Down rove focus (wrapping), Home/End jump to the edges, Escape
              closes and returns focus to the trigger, and an outside click closes
              it too. `aria-expanded` on the trigger stays honest the whole way.

              - **`toggle_attr(to, name, on, off)`** flips an attribute *between two
                values* — `js.toggle("#dm-menu").toggle_attr("#dm-trigger",
                "aria-expanded", "true", "false")`. An absent attribute becomes `on`.
              - **`expanded:`** on `show`/`hide`/`toggle` mirrors the op's intended
                state into the trigger's `aria-expanded` — `js.hide("#dm-menu",
                expanded: "#dm-trigger")` writes `"false"`, before any transition.
              - **`reactive_listnav(focus: true)`** on the `role="menu"` list gives
                roving focus among `[role=menuitem]`.
              - **Two `on_client` calls on one element** compose through `mix`: the
                trigger binds `click` and `keydown.down`, the root binds the
                outside click and `keydown.esc`.
            MD
            render Views::Examples::LiveExample.new(
              component: DisclosureMenuComponent.new,
              filename: 'app/components/disclosure_menu_component.rb'
            )
          end
        end

        def ops
          DocsUI::Section('The op vocabulary') do
            md <<~MD
              Ops are built with the server-side `js` helper and serialized into a
              `data-reactive-ops` attribute the client interprets. An op name not on
              the whitelist is warn-and-skipped (client-side default-deny) — a stale
              or newer ops attribute can never break the page. In development and
              test (`verbose_errors`, #237) an op whose selector resolves to **zero
              elements** console-warns once per unique case, with a hint —
              `to: :root` / `global: true` — when the element exists but sits
              outside the op's scope (the root itself, a nested reactive root, or
              elsewhere in the document). Production stays silent. `focus`/`focus_first`/
              `submit`/`paste_into` are allowed here (an actor's own gesture) but
              **rejected** from a broadcast — stealing focus in every subscriber's
              tab, force-submitting every subscriber's form, or reading every
              subscriber's clipboard, would be hostile.

              `text(to, value)` (#159) sets the target's `textContent` — stringified,
              `nil` clears, **never `innerHTML`** — so a chain can paint a label or a
              derived number without a round trip. Pair it with `global: true` to
              reach a node **outside** the component's root (the cross-root text
              escape a read-only recap needs).

              `submit(to = :root)` (#226) commits the **target's own form** via
              `requestSubmit()` — the target itself when it *is* a form, a
              control's form owner, else the nearest ancestor form. A real
              cancelable `submit` event fires, so a native/Turbo form navigates
              normally and an `on(:save, event: "submit")` interception turns it
              into a signed action. That makes the classic autosubmit filter one
              declared line, with Turbo Drive handling the visit:

              ```ruby
              form(action: "/products", method: "get") do
                select(name: "sort", **on_client(:change, js.submit("form"))) { sort_options }
              end
              ```

              `submitter:` (#319) submits **through** a named submit control —
              `form.requestSubmit(submitter)` — so the request carries its
              `name=value`: `js.submit("#bulk", submitter: "#delete-submit")`
              posts `bulk_action=delete`. The submitter resolves with the op's own
              scoping; one that is not a submit control of that form warns and
              falls back to a plain submit. (A selector target resolves *inside*
              the root, so when the form **is** the root, keep the default
              target: `js.submit(submitter: "#delete-submit")`.)

              Binding a submit op to the `submit` event itself raises at render —
              requestSubmit dispatches the very event the trigger would listen to.
              For "submit when a **text** value becomes complete", see the
              conditional forms below and the compute reducer's `$ops` output on
              the [payment-split example](/docs/example-payment-split).

              `paste_into(to)` (#228) reads the clipboard into a field on a
              **user gesture** — built for fields whose real `<input>` is
              visually hidden (an OTP cell UI), where right-click → Paste can
              never reach the editable input. On click it starts
              `navigator.clipboard.readText()` **fire-and-forget** (the
              permission UX is the browser's own; chained sibling ops apply
              immediately, never waiting for the read) and, when the read
              resolves, feeds the text through the **normal `input`
              pipeline**: set `.value`, dispatch a bubbling `input` (compute
              reducers, `reactive_show`, `reactive_on_complete` run exactly as
              if typed), then focus the field so a partial paste continues from
              the caret. A denied read, empty text, or a missing API is a
              **silent no-op**. The trigger is marked `data-reactive-clipboard`
              and the controller sets `hidden = !available` on connect — author
              it `hidden` and a dead button never shows. The gate **owns** the
              trigger's `hidden` flag: render it unconditionally, and don't also
              bind `reactive_show` to the trigger element:

              ```ruby
              button(hidden: true,
                **mix(on_client(:click, js.paste_into("[name=code]")),
                  class: "btn")) { "Paste code" }
              ```
            MD
            DocsUI::Callout(:tip) do
              md <<~MD
                Reach for `on_client` whenever the interaction is purely presentational
                — toggling a disclosure, closing a popover, moving focus. Reach for a
                reactive `action` (a token + POST) only when the server must **decide**
                or **persist** something.
              MD
            end
          end
        end

        def value_conditional
          DocsUI::Section('Value-conditional visibility (reactive_show)') do
            md <<~MD
              `on_client` ops are *unconditional* — they can't read the triggering
              field's value to **decide** show vs hide. `reactive_show` (#180) covers
              exactly that gap, the Alpine `x-show` / Datastar `data-show` / Livewire
              `wire:show` case, in ONE Ruby-native conditions language: `if:` /
              `if_any:` / `unless:`, with `where`-style values. The generic
              controller toggles the `hidden` attribute from the fields' current
              values on every `input`/`change`. Still client-only: no token, no POST.

              A **Hash is an AND**, an **Array is membership**, a **Range is a
              threshold**, `{ length: … }` compares the value's **codepoint
              count** (#226), `{ checked: … }` counts a checkbox group's ticked
              boxes (#319, see the bulk-selection section below), and
              `unless:` **negates** — the whole value vocabulary:

              ```ruby
              div(**reactive_show(unless: { mode: "off" }))            { "shipping details" }
              div(**reactive_show(if: { gift: true }))                 { "gift message" }   # checkbox checked
              div(**reactive_show(if: { delivery: "ship" }))           { "address fields" } # radio value
              div(**reactive_show(if: { size: %w[l xl] }))             { "surcharge note" } # membership
              div(**reactive_show(if: { quantity: 10.. }))             { "bulk note" }      # threshold
              div(**reactive_show(if: { code: { length: 6 } }))        { "ready badge" }    # exact length
              ```

              Extra HTML attrs pass through unambiguously (conditions live in `if:`),
              so `div(**reactive_show(if: { size: %w[l xl] }, class: "note"))` works.

              **OR-of-AND without the distributive law.** `if_any:` takes an array of
              AND-hashes — one level of disjunction, which covers every boolean
              visibility rule. This is the case that used to force hand-applied
              distributive law encoded as nested wrapper divs:

              ```ruby
              # visible while director OR (shareholder AND role == "individual")
              div(**reactive_show(if_any: [
                { director: true },
                { shareholder: true, role: "individual" }
              ]))
              # AND across fields, with negation, in one binding:
              div(**reactive_show(if: { type: "individual" }, unless: { country: "domestic" }))
              ```

              **First paint is computed for you.** Declare `reactive_values` once and
              every binding whose fields are all provided renders the correct initial
              `hidden:` server-side — no per-section mirror method, no flash:

              ```ruby
              def reactive_values = { director: @director, role: @role, quantity: @qty }
              # …then every reactive_show computes hidden: from these, automatically.
              ```

              `reactive_scope :form` lets bindings use bare symbols while the client
              resolves `[name="form[field]"]`, and `disable: true` disables a hidden
              section's own controls so a switched-away value never submits. A blank
              or non-numeric field fails a numeric term **closed** (stays hidden) —
              the safe default. There is no expression surface: every term is a
              declared literal, the same default-deny posture as before.

              A plain `reactive_show` is root-scoped by design. When the dependents
              live **outside** the control's root — a nav tab, a panel in another
              tab pane, a sidebar note — `reactive_show_targets` (#164) is the
              declared escape: the component that **owns** the field declares which
              outside ids it governs, spread on the root, using the same `where`-style
              values. Id selectors only (raise at render, warn-and-skip on the client
              — two-sided default-deny); a target id not on the page is skipped.

              ```ruby
              div(**mix(reactive_root, reactive_show_targets(:mode,
                "#advanced-tab" => "advanced",         # equals
                "#premium-note" => %w[gold platinum])))  # membership
              ```

              A `"#id"` **key** takes a full `if:`/`if_any:`/`unless:` conditions
              Hash (#209), so a cross-root target can read a **combination** of
              owned fields — the case that used to force a bespoke two-field JS
              listener. The fold matches an in-root `reactive_show` exactly (each
              term reads its own field; a missing owned field reads as blank —
              fail-closed), and target-keyed entries mix with field-keyed ones in
              the **one** call per root:

              ```ruby
              reactive_show_targets(
                "#bulk-alert" => { if: { type: "company", quantity: 10.. } },
                mode: { "#advanced-tab" => "advanced" }
              )
              ```

              **Conditional OPS — `reactive_on_complete` (#226).** `reactive_show`
              decides *visibility* from a condition; `reactive_on_complete` runs a
              **client-op chain** on the condition's rising edge — once, when it
              first becomes true; going false re-arms; the connect/morph pass arms
              *without* firing, so a re-render with already-satisfied conditions
              never self-fires. Same `if:`/`if_any:`/`unless:` kwargs, `run:` takes
              a `js` chain (class-level `js` is available in the declaration):

              ```ruby
              reactive_state :code
              action :verify, params: { code: :string }
              reactive_on_complete if: { code: { length: 6 } }, run: js.dispatch("code:complete")

              def view_template
                div(**mix(reactive_root, on(:verify, event: "code:complete"))) do
                  input(name: "code")
                end
              end
              ```

              That is a complete auto-committing verification-code field with
              **zero JavaScript** — the dispatch bubbles to the root's own
              `on(:verify, event: "code:complete")`, which turns completion into
              one signed action POST. `run: js.submit` commits the surrounding
              form instead. When completion needs **normalization first** (strip
              separators, cap length), put the condition in the reducer and use
              its `$ops` output — see the
              [compute example](/docs/example-payment-split).
            MD
            render Views::Examples::LiveExample.new(
              component: ConditionalFieldsetComponent.new,
              filename: 'app/components/conditional_fieldset_component.rb'
            )
          end
        end

        def bulk_selection
          DocsUI::Section('Bulk selection (reactive_select_all, reactive_count, reactive_enable)') do
            md <<~MD
              A list with a checkbox per row, a "select all" header, a
              "Delete (2)" count, and actions that stay disabled until something
              is ticked — the table every admin screen has — without a per-list
              JavaScript controller (#319):

              ```ruby
              def reactive_values = { "ids[]" => [] }   # first paint: nothing ticked

              def view_template
                div(**reactive_root) do
                  form(id: "bulk", action: "/posts/bulk", method: "post") do
                    input(type: "checkbox", **reactive_select_all("ids[]"))   # header
                    @posts.each { |post| input(type: "checkbox", name: "ids[]", value: post.id) }

                    span(**reactive_count("ids[]")) { "0" }                   # ticked count
                    fieldset(**reactive_enable(if: { "ids[]" => { checked: 1.. } })) { bulk_fields }
                    button(type: "button",
                           **mix(reactive_enable(if: { "ids[]" => { checked: 1.. } }),
                                 on_client(:click, js.submit("#bulk", submitter: "#delete-submit"),
                                           confirm: "Delete the selected posts?"))) { "Delete" }
                    button(type: "submit", name: "bulk_action", value: "delete", hidden: true, id: "delete-submit")
                  end
                end
              end
              ```

              - **`reactive_select_all(group)`** — the header box. Its edit ticks
                or unticks every **owned** box of the group and dispatches
                `input` + `change` on each one it flips (computes, shows and completions
                re-run). Its own state follows the group: checked when all are
                ticked, **indeterminate** when some are, unchecked when none are.
                Give it no `name`.
              - **`reactive_count(group)`** — the ticked count via `textContent`,
                change-guarded. Seed first paint in its block.
              - **`{ checked: n }` / `{ checked: 1.. }`** — a term in the shared
                conditions language: how many owned boxes of the group are ticked,
                with `length:`'s Integer and Range shapes. It works in
                `reactive_show`, `reactive_enable`, `reactive_on_complete`,
                `reactive_show_targets` and a conditional `confirm:`, and first
                paint evaluates it from `reactive_values` (an Array of checked
                values is counted; an Integer is the count).
              - **`reactive_enable(if:/if_any:/unless:)`** — `reactive_show`'s
                sibling: the same conditions and first paint, but it flips the
                element's own `disabled` (a button, a fieldset).
              - **Rows added later** by a Turbo stream `append` — or removed —
                re-sync the header, the count, `reactive_enable` and `reactive_show`: a root with a
                group binding watches its subtree for added or removed checkboxes.
              - A nested reactive root's boxes are never counted or flipped by
                the outer root (#15 ownership).
              - The Delete button confirms, then submits **this** form through
                the hidden submitter, so the POST carries `bulk_action=delete` and
                the ticked `ids[]`. A cancelled confirm submits nothing.
              - **`js.check_group(group, checked = true)`** (#342) — "Clear
                selection ✕" from any control: it unticks (`false`) or ticks
                every owned box of the group the way the header does, then
                re-syncs the header, the count, the shows and the enables once.
                `global: true` (a trigger outside the owning root) flips the
                group in every reactive root that owns boxes of it. Actor-only: a broadcast refuses it.
                `button(type: "button", **on_client(:click, js.check_group("ids[]", false))) { "✕" }`
              - A form **`reset`** inside the root re-syncs the group bindings, so
                a `type: "reset"` button never leaves a stale count.
            MD
          end
        end

        def client_drafts
          DocsUI::Section('Client-only drafts (reactive_persist)') do
            md <<~MD
              "Don't make me start over." A public application form, a wizard, a
              long comment box: the user types, navigates away, comes back, and
              expects the draft. Nothing the server needs until submit, no
              signed-in user to autosave for — so every app hand-rolls the same
              `localStorage` Stimulus controller (read, parse, TTL, restore,
              clear). `reactive_persist` (#239) is the `reactive_show`-shaped
              answer: a **declared, client-only** binding over the fields the
              root **owns** — no token, no POST, no expression surface.

              ```ruby
              div(**mix(reactive_root(id: "apply"), reactive_persist(key: "village-apply", ttl: 7.days))) do
                input(**reactive_field(:name))                       # persisted
                input(name: "fuckery", **reactive_persist_skip)      # honeypot — never
                input(type: "hidden", name: "apply[tz]")             # hidden — never (default)
                button(**on_client(:click, js.persist_state(step: 2))) { "Next" }
                button(**on_client(:click, js.persist_clear)) { "Discard draft" }
              end
              ```

              Spread on the **root**, once. The controller **writes** a snapshot
              of every owned control on `input` (trailing-edge debounce,
              `debounce:` ms) and immediately on `change`, and **flushes** a
              pending write on disconnect so a fast Turbo visit never loses the
              last keystrokes. It **restores** on connect — *first* among the
              client bindings, so a `reactive_show` section, an armed
              `reactive_on_complete`, a filter and a compute root all read the
              restored values on first paint with no synthetic events — and
              never re-restores over a morph (server truth). By default a draft
              lands only in a control the server rendered **blank**
              (`restore: :blank`): a 422 re-render's submitted values beat an
              older draft; `restore: :always` lets the draft win. It **clears**
              on a successful `turbo:submit-end` of the containing form, on
              `ttl` expiry, or via `js.persist_clear` — never on a successful
              reactive action by itself (chain `reply.js(js.persist_clear)`).

              Never persisted: `hidden`/`file`/`password`/`submit` controls,
              anything carrying `reactive_persist_skip`, and a nested root's
              controls. Rich editors (#241) — a named `lexxy-editor`,
              `trix-editor` or bare `[contenteditable]` — are drafted and
              restored through their **own** value surface (the editor's
              `value` setter, a contenteditable's `textContent`; never
              `innerHTML`), and `restore: :blank` asks the editor whether it is
              empty. `autocomplete="off"` is **not** an implicit skip —
              **honeypots must opt out** or sit outside the root.
              `fields:` narrows to declared names. `js.persist_state(step: 2)`
              merges a flat state bag into the draft; on restore the root carries
              `data-reactive-persist-state` and dispatches
              `reactive:persist-restored` (`detail: { key, fields, state }`) —
              the hook for a wizard to jump to its saved step. Storage failures
              (private window, quota, blocked) are silent; under
              `Phlex::Reactive.debug` one `console.info` names the failure.
            MD
            render Views::Examples::LiveExample.new(
              component: PersistFormComponent.new,
              filename: 'app/components/persist_form_component.rb'
            )
          end
        end

        def when_to_use
          DocsUI::Section('The zero-fetch contract') do
            md <<~MD
              Because the component declares no actions and every trigger is
              `on_client`, a click here never mints a token and never posts. That is
              the tested contract: the browser suite spies on `fetch` and asserts it
              is called **zero** times across every tab switch, menu toggle, and
              drawer open.
            MD
          end
        end
      end
    end
  end
end
