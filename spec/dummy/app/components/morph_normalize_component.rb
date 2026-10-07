# frozen_string_literal: true

# Issue #338: a debounced save whose server-side normalisation changes the
# value. Each save strips the text and replies reply.morph; the slug field is
# never typed in, only rendered from the saved name. The focused field must
# keep what the user typed (the trailing space) while the unfocused slug takes
# the server's value from the same morph.
class MorphNormalizeComponent < ApplicationComponent
  include Phlex::Reactive::Streamable
  include Phlex::Reactive::Component

  reactive_state :name, :body

  action :save_name, params: { name: :string }
  action :save_body, params: { body: :string }

  def initialize(name: "", body: "")
    @name = name
    @body = body
  end

  def id = "morph_normalize"

  def save_name(name:)
    @name = name.to_s.strip
    reply.morph
  end

  def save_body(body:)
    @body = body.to_s.strip
    reply.morph
  end

  def view_template
    div(id:, **reactive_attrs) do
      input(**mix(on(:save_name, event: "input", debounce: 150),
        name: "name", value: @name, data: { testid: "name" }))
      input(name: "slug", value: @name.parameterize, readonly: true, data: { testid: "slug" })
      textarea(**mix(on(:save_body, event: "input", debounce: 150),
        name: "body", data: { testid: "body" })) { @body }
      span(data: { testid: "saved_name" }) { @name }
      span(data: { testid: "saved_body" }) { @body }
    end
  end
end
