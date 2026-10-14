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
          waiting
          disclosure_menu
          modal_dialogs
          media_previews
          preview_file
          image_fallback
          kept_ops
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
              `focus`/`focus_first`/`blur`, `show_modal`/`close_dialog`, `copy_media`, `text`, `set_value`,
              `dispatch`, `submit`, `paste_into`, `preview_file` —
              each a local DOM mutation, with three deliberate exceptions. `submit`
              hands the form to its own native/intercepted submit path — the form
              may POST or navigate from there, but that is the form's contract,
              not the op's. `paste_into` (#228) **reads** the clipboard, behind
              the browser's own gesture and permission gates, and still only
              writes locally. `preview_file` (#375) **reads** the chosen `File`
              from the input's `files` and paints it through an object URL it
              makes itself — nothing is uploaded. Everything else sends nothing
              and reads nothing back.

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

        def waiting
          DocsUI::Section('Waiting: debounce: and throttle:') do
            md <<~MD
              `on_client` takes the same `debounce:` and `throttle:` keywords as `on`
              (#393): non-negative Integer milliseconds, never both at once (that
              raises at render, as `on` does). The client waits on the same timers
              `on` uses, then runs the ops locally — no round trip.

              - **`debounce: 300`** is trailing-edge: a burst of events runs the ops
                **once**, 300 ms after the last one. A new event inside the window
                replaces the pending run, and leaving the field (blur) runs it now.
              - **`throttle: 250`** is leading-edge: the first event runs the ops at
                once, and further events are dropped until 250 ms have passed.
              - **`once: true`** still means one run for the life of the element,
                after the wait.

              ```ruby
              input(**on_client(:input, js.submit("#search"), debounce: 300))
              div(**on_client(:scroll, js.add_class("#bar", "stuck"), window: true, throttle: 250))
              ```

              Type below and stop: the plain binding runs on every key, the debounced
              one once. Both sit on one input through `mix`.
            MD
            render Views::Examples::LiveExample.new(
              component: TypingPauseComponent.new,
              filename: 'app/components/typing_pause_component.rb'
            )
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
              - **`js.blur(to)`** (#399) blurs the focused element when it is the
                target or sits inside it, and leaves focus elsewhere alone. A menu
                shown by `:focus-within` closes on Escape only once its field loses
                focus — hiding it is not enough:
                `div(id: "menu", **on_client("keydown.esc", js.blur("#menu")))`.
                Actor-only, like `focus`.
            MD
            render Views::Examples::LiveExample.new(
              component: DisclosureMenuComponent.new,
              filename: 'app/components/disclosure_menu_component.rb'
            )
          end
        end

        def modal_dialogs
          DocsUI::Section('Modal dialogs') do
            md <<~MD
              A `<dialog>` opened with `showModal()` is a **real** modal: the browser
              puts it in the top layer, keeps Tab and Shift+Tab inside it, draws
              `::backdrop`, closes it on Escape and puts focus back on whatever
              opened it. Two ops reach it (#365), and one marker covers a dialog
              the server renders open.

              - **`js.show_modal(to)`** calls `showModal()`. A dialog already open
                *non*-modally is closed and reopened as a modal in the same task; one
                already modal is left alone; a target that is not a `<dialog>` is
                skipped (warned under `verbose_errors`/debug).
              - **`js.close_dialog(to)`** calls `close()`; a closed dialog is left alone.
              - **`data: { reactive_modal: true }`** on a `dialog(open: …)` the server
                renders — on a full page, in a reply, in a broadcast — makes it modal
                as soon as the client sees it: at connect, after a morph, and after a
                stream that brings a dialog. When a morph renders it **without**
                `open`, the client closes it with `close()`, so the page behind takes
                clicks and focus again.

              ```ruby
              button(**on_client(:click, js.show_modal("#picker"))) { "Choose…" }
              dialog(id: "picker", aria_labelledby: "picker-title") do
                h2(id: "picker-title") { "Choose an item" }
                button(**on_client(:click, js.close_dialog("#picker"))) { "Close" }
              end

              # "Is it open?" as server state, rendered open by a reply or a broadcast:
              # Escape fires `cancel`: bind it to an action so the server closes it too.
              dialog(**mix(on(:cancel, event: "cancel"), id: "confirm", open: @confirming,
                           data: { reactive_modal: true })) { … }
              ```

              Both ops are **actor-only**, like `focus`: `on_client`, `reply.js` and a
              reducer's `$ops` may use them, `broadcast_to(js:)` refuses them — opening
              a modal on every subscriber's screen at once would steal every
              subscriber's focus. To show a dialog everywhere, broadcast a render with
              the dialog open and the marker.
            MD
            DocsUI::Callout(:warning) do
              md <<~MD
                A dialog opened by `show_modal` is client state, and a server re-render
                resets it like any other op: a morph of a root whose render has the
                dialog **closed** closes it. When an action inside the dialog re-renders
                its root, keep "open" on the server instead (`open: @open` plus the
                marker), and close it with an action — and bind the dialog's `cancel`
                event (Escape) to that action to keep the server in step.
              MD
            end
            render Views::Examples::LiveExample.new(
              component: ModalPickerComponent.new,
              filename: 'app/components/modal_picker_component.rb'
            )
          end
        end

        def media_previews
          DocsUI::Section('Media previews (copy_media, reactive_media)') do
            md <<~MD
              `set_attr` refuses `src` (#96): a URL in an op could carry a `javascript:`
              payload. To point a preview at an image, render every candidate `<img>`
              on the server and **copy** one. No op or binding takes a URL (#373).

              - **`js.copy_media(to, from:)`** copies `src`, `srcset` and `alt` from the
                `from` `<img>` onto the `to` `<img>`. Both are `:root` or a selector,
                resolved with the op's own scoping (`global: true` reaches the whole
                document). The browser reads the URL from the source element itself;
                it is never an argument. A missing source or a source that is not an
                `<img>` clears the target's `src`, `srcset` and `alt`. An `<img>`
                source without `src` is a hit with no image (#381): the target loses
                `src` and `srcset` and takes the source's `alt`. A target that is not an `<img>` (an `iframe`, `script`,
                `object`, `embed`, `frame`, …) is warned about and skipped. Copying the
                URL the target already shows writes nothing, so the image does not
                reload. A broadcast may carry it: it only reads elements that are
                already on each subscriber's page.
              - **`reactive_media(from:, pool:, take: nil, match: nil, pending: :clear, label: nil, blank_label: nil)`**
                is a binding, read the way `reactive_show` reads a field: a text field
                gives its value, a radio group its checked value, `reactive_scope`
                applies. `take: n` (a positive Integer) keeps the first *n* characters
                as the key; omit it to use the whole value. The key looks up `pool`,
                whose values are **selectors** for `<img>` elements inside the root,
                never URLs. A key, selector or element that misses clears the preview.
                A pool `<img>` with an `alt` and no `src` (an entry with no logo file)
                is a hit: the preview drops its image and `label:` still gets the name.
                `label:` names a node whose `textContent` becomes the chosen image's
                `alt`, or `blank_label` (empty when omitted) on a miss.
              - **Pending (#380).** A value shorter than `take:` characters is not a
                miss yet: the binding is *pending* and never writes `blank_label`.
                `match:` (a Regexp, matched against the whole key) makes a key it
                rejects pending too, so `"ab1"` waits instead of reading "Unknown".
                `pending: :clear` (the default) clears the preview and empties the
                label; `pending: :keep` leaves both as they are. The preview carries
                `data-reactive-media-state="pending|hit|miss"`, so a row can hide
                itself with CSS until there is an answer (the demo below uses
                Tailwind's `has-[[data-reactive-media-state=pending]]:invisible`).
                `match:` is sent to the browser as a JavaScript pattern: its `\\A`
                and `\\z` anchors are dropped (the client anchors it), and what
                JavaScript reads differently raises at render: options (`i`, `m`,
                `x`), escapes such as `\\h`, `\\p{…}`, `\\s` and `\\u{…}`, POSIX `[[:digit:]]`,
                nested classes, `&&`, `(?i)`/`(?>…)` groups and characters above
                U+FFFF. The state is written once the client connects; to hide the
                row on first paint too, render the preview with
                `data: { reactive_media_state: "pending" }`.

              ```ruby
              input(name: "code")
              div(id: "logo-row") do
                img(id: "logo", alt: "", **reactive_media(
                  from: :code, take: 3, match: /\\A\\d{3}\\z/,
                  pool: { "007" => "#logo-007", "011" => "#logo-011" },
                  label: "#caption", blank_label: "Unknown",
                  data: { reactive_media_state: "pending" } # hidden on first paint, too
                ))
                span(id: "caption")
              end
              img(id: "logo-007", src: "/logos/007.svg", alt: "North", hidden: true)
              img(id: "logo-011", src: "/logos/011.svg", alt: "South", hidden: true)

              button(**on_client(:click, js.copy_media("#logo", from: "#logo-007"))) { "Use north" }
              ```

              ```css
              /* hide the row until three digits are typed */
              #logo-row:has([data-reactive-media-state="pending"]) { display: none; }
              ```

              `js.copy_media("#logo")` without `from:`, `reactive_media` without
              `pool:`, and a `take:` that is not a positive Integer raise at render.
              When the field value *is* the whole key and the images differ in more
              than the picture, `reactive_show` over pre-rendered blocks is the
              simpler tool; `reactive_media` is for a key that is a prefix of a
              longer value.
            MD
            render Views::Examples::LiveExample.new(
              component: MediaPreviewComponent.new,
              filename: 'app/components/media_preview_component.rb'
            )
          end
        end

        def preview_file
          DocsUI::Section('Preview a chosen image') do
            md <<~MD
              Choosing a file should show it **before** the upload. `js.preview_file`
              (#375) does that on the file input's `change`, with no round trip and no
              Stimulus controller:

              ```ruby
              input(type: "file", id: "photo-file", accept: "image/*",
                **on_client(:change, js.preview_file("#photo-file", into: "#photo", name: "#photo-name")))
              img(id: "photo", alt: "")
              span(id: "photo-name")
              ```

              - The client takes the input's first `image/*` file, makes an object URL
                from it (`URL.createObjectURL`), sets it as the `img`'s `src`, and puts
                `file.name` in the `name:` node (optional) as `textContent`.
              - An empty selection or a non-image file removes the `src` and clears the name.
              - The runtime keeps the last URL per `img` and **revokes** it on the next
                choice, on a clear, and when the `img` leaves the page or a morph strips
                its `src` — no blob URL leaks.
              - The op carries **no URL**. There is no parameter for one, the client never
                reads a `url` key, and `set_attr` of `src` (and `srcset`, #373) stays refused (#96). Only an
                `<img>` ever gets a `src`: an `into:` that is anything else, or a `to` that
                is not an `input[type=file]`, warns and is skipped.
              - `to`, `into:` and `name:` resolve inside the component's root by default
                (`global: false`). `global: true` resolves all three document-wide, for an
                `img` outside the root.
              - **Actor-only** like `paste_into`: `on_client` and `reply.js` may use it,
                `broadcast_to(js:)` refuses it.

              **When the app rejects the file.** An upload validator (size, type) often rejects a file by clearing the input
              itself. `input.value = ""` fires no `change`, so the op never hears about it
              and the rejected image stays on screen. Two pieces close that gap (#382):

              ```ruby
              op = js.preview_file("#photo-file", into: "#photo", name: "#photo-name", valid: true)
              input(type: "file", id: "photo-file", accept: "image/*",
                **mix(on_client(:change, op), on_client("reactive:file-changed", op)))
              ```

              - **`valid: true`** treats an input whose `validity.valid` is false as empty.
                A validator that calls `input.setCustomValidity("Too big")` before the op
                runs means the file never gets a preview, and a preview already shown is
                cleared and its URL revoked.
              - **`reactive:file-changed`** is the event for "the app changed this input's
                files without a `change` event". Bind the same op to it, and have the
                validator dispatch it after it clears or invalidates the field:

              ```js
              input.value = ""
              input.dispatchEvent(new CustomEvent("reactive:file-changed", { bubbles: true }))
              ```

              The event works whichever `change` listener runs first, the validator's or
              the op's. `valid: true` on its own needs the validator to have run before the
              op on the same `change`; when that order is not certain, dispatch the event. Without `valid:`
              the op previews whatever file the input holds, as before.
            MD
            DocsUI::Callout(:warning) do
              md <<~MD
                The preview is client state: a server re-render of the root renders the
                `img` without the preview's `src` and resets it, and the runtime revokes
                the URL. `keep:` (#369) does not cover it — it keeps classes, `hidden`
                and allowlisted attributes, and `src` is not one of them.
              MD
            end
            render Views::Examples::LiveExample.new(
              component: PhotoPreviewComponent.new,
              filename: 'app/reactive_components/photo_preview_component.rb'
            )
          end
        end

        def image_fallback
          DocsUI::Section('An image that falls back, and recovers') do
            md <<~MD
              A preview that `copy_media`, `reactive_media` or `preview_file` points at a
              broken URL should not show a broken-image icon, and the **next** good URL
              should show it again. `reactive_image_fallback` (#383) does both, with no
              Stimulus controller to reset by hand:

              ```ruby
              input(name: "rib")
              img(id: "logo", alt: "", **reactive_media(
                from: :rib, take: 3,
                pool: { "001" => "#bank-001", "007" => "#bank-007" },
                **reactive_image_fallback(hide: true)
              ))
              img(id: "bank-001", src: "/banks/missing.svg", alt: "Broken Bank", hidden: true)
              img(id: "bank-007", src: "/banks/007.svg", alt: "Attijariwafa", hidden: true)

              # Or swap the image for its alt text in a node inside the root:
              img(id: "copied", alt: "Bank", **reactive_image_fallback(show_alt: "#bank-name"))
              span(id: "bank-name", hidden: true)
              ```

              - On `error` the `img` gets `data-reactive-image-state="error"`. With
                `hide: true` (the default) it is hidden; with `show_alt:` its `alt` is
                written (as `textContent`) into that node, which is shown. `hide: false`
                only sets the state, for CSS: `img[data-reactive-image-state=error]`.
              - On `load` the state is `"loaded"`.
              - **A later `src` tries again.** `copy_media`, `reactive_media` and
                `preview_file` clear the error as they write the `src`; any `src` that
                loads clears it on `load`; a morph that changes the `src` lets the browser
                try the new one. A morph that keeps the same `src` keeps the state.
              - **No `src` is not an error.** Removing it (a `reactive_media` miss, a
                `copy_media` from a missing source) clears the state and shows the `img`.
              - Only the `hidden` the fallback added is removed: an `img` the server
                rendered `hidden` stays hidden.
              - `show_alt:` is a selector resolved inside the `img`'s own reactive root,
                never a URL. `hide:` that is not `true`/`false`, or a `show_alt:` that is
                not a non-blank String (or is `@root`), raises at render. A String that
                is not a valid CSS selector, or a node that holds the `img`, is ignored
                by the client.
              - The client listens once on the document (`error` and `load` do not
                bubble, so it listens in the capture phase): nothing runs per root at
                connect.
            MD
          end
        end

        def kept_ops
          DocsUI::Section('Keeping client state through a morph') do
            md <<~'MD'
              A morph — `reply.morph`, `broadcast_to(…, morph: true)`, a page-refresh morph —
              writes `class`, `hidden` and every attribute back from the server render.
              Client ops record nothing, so a selection made with `add_class` is gone the
              moment another viewer's change morphs the list. **`keep: true`** (#369)
              marks an op's result as the client's own:

              ```ruby
              class ItemList < Phlex::HTML
                include Phlex::Reactive::Component

                reactive_record :list
                def id = "item-list"

                def view_template
                  div(**reactive_root) do
                    @list.items.each do |item|
                      div(**mix(on_client(:click, select(item)), id: "item-#{item.id}", class: "item")) do
                        plain item.name
                        div(id: "details-#{item.id}", class: "details", hidden: true) { item.notes }
                      end
                    end
                  end
                end

                private

                # Clear all, then select one — every op kept.
                def select(item)
                  js.remove_class(".item", "selected", keep: true)
                    .hide(".details", keep: true)
                    .add_class("#item-#{item.id}", "selected", keep: true)
                    .show("#details-#{item.id}", keep: true)
                end
              end

              # Another viewer renames item 3; everyone's list is morphed —
              # and the item each viewer selected stays selected in their tab.
              ItemList.broadcast_to(list, :items, replace: list, morph: true)
              ```

              - **What is kept** is the op's *result* on each target: the class on or
                off, `hidden`, the attribute's value or its absence. A `toggle_class` or
                `toggle` puts back the state it left; it does not flip again.
              - **The latest kept op wins** per element and class or attribute, so the
                kept `remove_class` above cancels the previous selection's kept
                `add_class` — one item stays selected, not every item ever clicked.
                An op **without** `keep:` leaves an earlier kept record alone: a panel
                shown with `show(…, keep: true)` and closed with a plain `hide` opens
                again on the next morph. Close it with `hide(…, keep: true)`.
              - **The render still lands.** A class or attribute no kept op touched
                follows the server, so the renamed item's own changes appear.
              - **A replaced element starts clean.** `keep:` holds through a *morph*,
                which keeps the element; a stream that replaces it brings a new element
                with no kept state.
              - `keep:` takes the same ops in the client `ops` builder:
                `ops.add_class("#item-2", "selected", { keep: true })`. With `expanded:`,
                the trigger's `aria-expanded` is kept too.

              `broadcast_to(js:)` **refuses** `keep: true` (an `ArgumentError` naming
              `keep`): kept state belongs to one tab, like `focus`. When the server must
              know the selection — to filter, to show other viewers — keep it on the
              server (an action or [presence](/docs/presence)) instead.
            MD
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
              elsewhere in the document). Production stays silent. `focus`/`focus_first`/`blur`/
              `show_modal`/`close_dialog`/`submit`/`paste_into`/`preview_file`/`set_value` are allowed here (an
              actor's own gesture) but **rejected** from a broadcast — stealing focus
              in every subscriber's tab, opening a modal on every subscriber's screen,
              force-submitting every subscriber's form, reading every
              subscriber's clipboard, or overwriting every subscriber's field, would be hostile.

              `text(to, value)` (#159) sets the target's `textContent` — stringified,
              `nil` clears, **never `innerHTML`** — so a chain can paint a label or a
              derived number without a round trip. Pair it with `global: true` to
              reach a node **outside** the component's root (the cross-root text
              escape a read-only recap needs).

              `set_value(to, value)` (#374) fills a **field** — an `input`,
              `textarea` or `select` — from text already on the page, with no
              clipboard and no round trip. It assigns the live `.value` (never the
              attribute, never parsed as HTML; stringified, `nil` and `""` clear),
              then dispatches one bubbling `input` **when the value changed**, so
              compute reducers and `reactive_show` react as if the user typed. It
              never dispatches `change` and never moves focus: chain
              `.focus("#notes")` for that. A `select` selects the matching option; a
              file input accepts `""` only, which clears the chosen files. Anything
              else (a `contenteditable`, which `reactive_editable` writes; a
              non-field; a non-empty value for a file input) warns and is skipped.
              `:root` raises at render: the root is not a field. On a checkbox or
              radio it sets the submitted value, not the checked state: tick boxes
              with `check_group` or a click.

              ```ruby
              button(**on_client(:click,
                js.set_value("#notes", "Thanks for your order.").set_value("#template_key", "thanks")
              )) { "Thanks" }
              ```

              Why not `set_attr("#notes", "value", …)`? That writes the **attribute**:
              a field the user has typed in keeps its live value, and no `input`
              fires, so reducers and `reactive_show` stay stale. `set_value` is
              actor-only (refused by `broadcast_to(js:)`; render the value instead)
              and is on the reducer builder too: `$ops: ops.set_value("#notes", "…")`.
              Its `input` re-runs the reducer, so never derive the value from the
              field it writes (the chain changes every pass and fires again each
              time); return a field the reducer owns as an output instead.

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

              **A bulk bar outside the list's root.** When the list is its own
              reactive root (an action filters or paginates it), the page's
              bindings cannot see its boxes. The owning root declares the
              outside ids it drives instead, next to `reactive_show_targets`
              (#343):

              ```ruby
              div(**mix(reactive_root,
                reactive_show_targets("#bulk-bar" => { if: { "ids[]" => { checked: 1.. } } }),
                reactive_group_targets("ids[]",
                  count:  "#bulk-count",                    # textContent = ticked count
                  enable: { "#bulk-archive" => 1.. })))     # disabled = !(count in range)

              # outside, first paint from the page's reactive_values:
              span(id: "bulk-count") { reactive_group_target_attrs("ids[]", :count).to_s }
              button(id: "bulk-archive", **reactive_group_target_attrs("ids[]", :enable, 1..)) { "Archive" }
              ```

              Targets are id selectors only, resolved document-wide; an
              `enable:` value is an Integer, a Range or a conditions Hash. They
              re-sync on every change, a morph of the owning root, and rows
              added or removed. One call per root (the hash form takes several
              groups).
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
