# frozen_string_literal: true

# Issue #275: a draft-keeping root that ALSO posts an action. The draft code is
# a feature module the client imports on demand, so its restore runs a moment
# after the controller connects — and an action fired in that window must post
# the restored values, not the blanks the server rendered. `save` echoes the
# `note` it received, so the system spec can read exactly what was posted.
class PersistActionComponent < ApplicationComponent
  include Phlex::Reactive::Component

  skip_verify_authorized

  reactive_state :saved
  action :save, params: { note: :string }

  def initialize(saved: nil)
    @saved = saved
  end

  def id = "persist-action"

  def save(note: nil) = @saved = "got:#{note}"

  def view_template
    div(**mix(reactive_root, reactive_persist(key: "dummy-persist-action", ttl: 1.hour, debounce: 0))) do
      input(type: "text", name: "note", data: { testid: "note" })
      input(type: "text", name: "extra", data: { testid: "extra" })
      p(data: { testid: "saved" }) { @saved.to_s }
      button(**mix(on(:save), data: { testid: "save" })) { "Save" }
    end
  end
end
