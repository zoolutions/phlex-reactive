# frozen_string_literal: true

module Views
  module Docs
    module Pages
      class EditableText < DocsUI::Page
        title 'Editable text'
        eyebrow 'Guide'
        description 'Edit text where it is shown in reactive Phlex for Rails: reactive_editable keeps typed text and the caret through a morph, pastes plain text, and handles Enter and Escape'

        def lead
          'Turn any element into a plain-text field with `reactive_editable`: an inline ' \
            'title, a card label, a note. Typed text and the caret survive the reply ' \
            'morph, paste is plain text, Enter and Escape do what a field should.'
        end

        def content
          try_it
          the_helper
          the_client
          styling
          notes
        end

        private

        def try_it
          DocsUI::Section('Try it') do
            md <<~MD
              Click the title and type: every pause saves (a debounced `input`
              action) and the reply morphs the card, yet the caret stays where it
              is and nothing you typed during the request is lost. **Enter** in the
              title moves to the note; the note keeps its line breaks. **Escape**
              reverts a field to its last saved text.
            MD
            render Views::Examples::LiveExample.new(
              component: EditableCardComponent.new(todo: editable_demo_todo),
              filename: 'app/components/editable_card_component.rb'
            )
          end
        end

        def the_helper
          DocsUI::Section('reactive_editable') do
            md <<~MD
              The element is yours; the helper renders its attributes. Bind an
              action with `on()` through `mix`, as for any field:

              ```ruby
              h3(**reactive_editable(:title, placeholder: "Untitled")) { @card.title }
              p(**reactive_editable(:summary, multiline: true)) { @card.summary }

              # Autosave while typing:
              h3(**mix(reactive_editable(:title), on(:rename, event: "input", debounce: 300))) { @card.title }
              ```

              It renders `name` (scope-aware, like `reactive_field`),
              `contenteditable="plaintext-only"`, `role="textbox"`,
              `aria-multiline`, `aria-placeholder` and `data-reactive-placeholder`,
              and the `data-reactive-editable*` markers the client reads.

              | Option | Default | Effect |
              |---|---|---|
              | `multiline:` | `false` | `true` keeps line breaks; single-line folds them to spaces and swallows Enter |
              | `placeholder:` | `nil` | `aria-placeholder` + `data-reactive-placeholder` for CSS |
              | `on_enter:` | `nil` | a `js` chain run on Enter (root-scoped, as `on_client`), or `:submit` to request-submit the field's form. In a multiline field Shift+Enter still breaks the line |
              | `on_escape:` | `:revert` | restore the last server-rendered text and blur; `nil` turns it off |
              | `spellcheck:` | `true` | `false` renders `spellcheck="false"` |

              It works in a `Phlex::Reactive::ClientBindings` view too (no token):
              there the field's text is drafted by `reactive_persist` and read by
              `reactive_show`.
            MD
          end
        end

        def the_client
          DocsUI::Section('What the client does') do
            md <<~'MD'
              - **The value.** The text with line breaks as `\n` (a `<br>` or a
                block element is one), `\r\n` normalised, one trailing newline
                dropped. A single-line field folds newlines to spaces.
              - **The morph.** While the field is focused, a `reply.morph` or a
                broadcast morph leaves its text and caret alone; its attributes
                (a validation class, `aria-invalid`) still update. Unfocused, the
                server's text wins. `data-reactive-morph-value` on the element lets
                the morph write it even while focused, as for inputs. The client
                copies a held field's attributes itself, so Turbo's
                `turbo:before-morph-attribute` and `turbo:morph-element` do not
                fire for that element while it is focused.
              - **Paste and drop** insert plain text: natively where the engine has
                `plaintext-only` (all current ones), through a handler where it does
                not. There the client switches every editable to
                `contenteditable="true"`, whenever it reaches the page (at load, by
                a stream, a frame or a morph), because such an engine cannot edit
                `plaintext-only` at all. Line breaks pasted into a single-line
                field become spaces.
              - **Enter** is left alone during IME composition.
              - **Dirty and drafts.** `reactive_dirty` marks the field when its text
                differs from the text of its last server render; `reactive_persist`
                drafts and restores it with its line breaks.

              A bare named `[contenteditable]` without the helper is still collected
              as before (its `textContent`) and is not held through a morph.
            MD
          end
        end

        def styling
          DocsUI::Section('Styling') do
            md <<~MD
              The placeholder and multi-line display are CSS's:

              ```css
              [data-reactive-placeholder]:empty::before {
                content: attr(data-reactive-placeholder);
                opacity: .4;
              }
              [data-reactive-editable="multi"] { white-space: pre-wrap; }
              ```

              The client removes the `<br>` browsers leave in a field emptied by
              the user, so `:empty` matches again.
            MD
          end
        end

        def notes
          DocsUI::Section('Notes') do
            DocsUI::Callout(:note) do
              md <<~MD
                The value travels with reactive actions. A native (non-reactive)
                form submit does not post a contenteditable, so bind the save with
                `on()` or `on_enter: :submit` on a form whose submit a reactive
                action intercepts. For rich text (bold, links) use an editor such as
                Lexxy or Trix, which the collector reads by its `.value`.

                An editable can arrive later: a stream can append it into a root
                that is already on the page. Its keys and paste work from its
                first focus. On the split client a stream that brings one starts
                loading the bindings module before it renders.
              MD
            end
          end
        end

        def editable_demo_todo
          Todo.find_or_create_by!(title: 'Click to rename this card')
        end
      end
    end
  end
end
