# frozen_string_literal: true

# Issue #370: the issue's reproduction. A debounced save whose title field is
# held by a broadcast morph (another tab changed it while this one typed)
# arrives with reactive_held_fields == ["title"]; the action refuses to
# overwrite the other change and shows both values instead.
class HeldNoteComponent < ApplicationComponent
  include Phlex::Reactive::Component

  reactive_record :todo
  action :save, params: { title: :string, version: :string }

  def initialize(todo:)
    @todo = todo
  end

  def id = "held-note"

  def save(title: nil, version: nil)
    @held = reactive_held_fields
    if @held.include?("title") && title != @todo.title
      @conflict = title
      return reply.morph
    end

    @todo.update!(title:) if title.present?
    reply.morph
  end

  def view_template
    form(**mix(reactive_root, on(:save, event: "input", debounce: 150))) do
      input(type: "hidden", name: "version", value: @todo.updated_at.to_f.to_s)
      input(name: "title", value: @todo.title, data: { testid: "title" })
      span(data: { testid: "saved" }) { @todo.title }
      span(data: { testid: "held" }) { Array(@held).join(",") }
      if @conflict
        p(data: { testid: "conflict" }) { "Someone changed the title to #{@todo.title} while you typed #{@conflict}" }
      end
    end
  end
end
