# frozen_string_literal: true

# Editable text (issue #351) end-to-end: an inline title typed into where it is
# shown. Every debounced `input` saves and replies with reply.morph; the
# server squishes the title (so its render can differ from what is typed —
# a trailing space), and stamps the saved length onto the editable as an
# attribute. While the title is focused the morph keeps its text and caret
# and still applies the attribute; Enter does nothing (single-line) and
# Escape reverts to the last saved text. Shout morphs it from a button, so
# the heading is not focused and takes the server's text.
class EditableTitleComponent < ApplicationComponent
  include Phlex::Reactive::Streamable
  include Phlex::Reactive::Component

  reactive_record :todo
  reactive_dirty
  action :rename, params: { title: :string }
  action :shout

  def initialize(todo:)
    @todo = todo
  end

  def id = dom_id(@todo, "editable")

  def rename(title:)
    @todo.update!(title: title.squish) if title.present?
    reply.morph
  end

  def shout
    @todo.update!(title: @todo.title.upcase)
    reply.morph
  end

  def view_template
    div(**reactive_root) do
      h3(
        **mix(
          reactive_editable(:title, placeholder: "Untitled"),
          on(:rename, event: "input", debounce: 300),
          data: { testid: "title", saved_length: @todo.title.length }
        )
      ) { @todo.title }
      span(class: "unsaved-badge", data: { testid: "badge" }) { "Unsaved" }
      span(data: { testid: "current" }) { @todo.title }
      button(**mix(on(:shout), data: { testid: "shout" })) { "Shout" }
    end
  end
end
