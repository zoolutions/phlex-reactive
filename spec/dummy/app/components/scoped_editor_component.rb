# frozen_string_literal: true

# Exercises reactive_scope on fields + the param schema (issue #184). Declaring
# `reactive_scope :todo` means reactive_field(:title) emits name="todo[title]",
# so the POST arrives bracketed — and the endpoint unwraps ONE scope level before
# schema matching, so the FLAT schema { title: :string } still matches (fixing the
# #67 bracket-drop footgun without a hand-nested schema).
class ScopedEditorComponent < ApplicationComponent
  include Phlex::Reactive::Streamable
  include Phlex::Reactive::Component

  reactive_record :todo
  reactive_scope :todo
  action :save, params: { title: :string } # FLAT — one name, scope handles the wire
  # A checkbox group under the same scope (issue #258): the DOM name is
  # todo[tags][], so a cleared group is announced as "todo[tags]" and has to land
  # where the FLAT schema looks for it.
  action :save_tags, params: { title: :string, tags: [:string] }
  # Issue #337: echoes what reached the action, so a spec can see every wire
  # shape land — scoped fields AND a bare trigger param (`note`, as `on(...)`
  # posts it) side by side.
  action :echo, params: { title: :string, tags: [:string], note: :string }

  def initialize(todo:)
    @todo = todo
  end

  def id = dom_id(@todo, "scoped_editor")

  def save(title:)
    @todo.update!(title:)
    reply.replace
  end

  def save_tags(title: nil, tags: nil)
    @received_tags = tags
    reply.replace
  end

  def echo(**received)
    @received = received
    reply.replace
  end

  def view_template
    div(id:, **reactive_root) do
      input(**reactive_field(:title, value: @todo.title, data: { testid: "title" })) # name="todo[title]"
      button(**mix(on(:save), data: { testid: "save" })) { "Save" }
      pre(data: { testid: "received-tags" }) { @received_tags.to_json }
      pre(data: { testid: "received" }) { @received.to_json }
      span(data: { testid: "saved-title" }) { @todo.title } # server-rendered: moves only on a real save
    end
  end
end
