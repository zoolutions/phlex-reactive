# frozen_string_literal: true

# Editable text (issue #351): a card whose title and note are edited where they
# are shown. reactive_editable renders the attributes onto your own element —
# contenteditable="plaintext-only", the param name, role="textbox" and the
# aria/placeholder hooks — and the client treats it like an input:
#
#   * its text travels as the param (line breaks as "\n" in the multiline note);
#   * a reply morph keeps the focused field's text and caret, so the debounced
#     autosave never eats what you type while it is in flight;
#   * paste is plain text; Enter in the single-line title moves to the note
#     (on_enter:), Escape reverts to the last saved text;
#   * reactive_dirty diffs it against that saved text, like an input.
class EditableCardComponent < Phlex::HTML
  include Phlex::Reactive::Streamable
  include Phlex::Reactive::Component

  reactive_record :todo
  reactive_state :note
  reactive_dirty
  action :rename, params: { title: :string }
  action :write, params: { note: :string }

  def initialize(todo:, note: "Line breaks survive.\nPress Escape to undo an edit.")
    @todo = todo
    @note = note
  end

  def id = dom_id(@todo, 'editable_card')

  def rename(title:)
    # A blank title is never saved; the card says so (the focused field keeps
    # what was typed, so Escape is the way back to the saved title).
    title = title.strip
    if title.empty?
      @blank_title = true
    else
      @todo.update!(title:)
    end
    reply.morph
  end

  def write(note:)
    @note = note
    reply.morph
  end

  def view_template
    # The placeholder is drawn by CSS from data-reactive-placeholder; the badge
    # shows while the root is dirty. Static CSS — Phlex safe(), not html_safe.
    style do
      css = '[data-reactive-placeholder]:empty::before{content:attr(data-reactive-placeholder);opacity:.4} ' \
            '[data-reactive-editable=multi]{white-space:pre-wrap} ' \
            '[data-testid="editable-badge"]{display:none} ' \
            '[data-reactive-dirty] [data-testid="editable-badge"]{display:inline-flex}'
      raw(safe(css)) # rubocop:disable Rails/OutputSafety
    end
    div(**reactive_root(class: 'card bg-base-200 max-w-md')) do
      div(class: 'card-body gap-3') do
        div(class: 'flex items-center gap-2') do
          h3(**mix(reactive_editable(:title, placeholder: 'Untitled', on_enter: js.focus('#editable-note')),
                   on(:rename, event: 'input', debounce: 400),
                   class: 'card-title outline-none focus:underline', data: { testid: 'editable-title' })) do
            @todo.title
          end
          span(class: 'badge badge-warning badge-sm', data: { testid: 'editable-badge' }) { 'Saving…' }
        end
        p(**mix(reactive_editable(:note, multiline: true, placeholder: 'Add a note'),
                on(:write, event: 'input', debounce: 400),
                id: 'editable-note', class: 'outline-none text-sm', data: { testid: 'editable-note' })) do
          @note
        end
        p(class: 'text-xs opacity-60') { "Saved title: #{@todo.title}" }
        p(class: 'text-xs opacity-60') { 'The note is demo state: it lives in the card, not in the database.' }
        if @blank_title
          p(class: 'text-xs text-warning', data: { testid: 'editable-blank' }) do
            'A title can’t be blank — not saved. Press Escape to restore it.'
          end
        end
      end
    end
  end
end
