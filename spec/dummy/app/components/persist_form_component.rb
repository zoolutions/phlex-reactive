# frozen_string_literal: true

# Issue #239: reactive_persist — a client-only localStorage draft over the
# fields the root OWNS. A token-less ClientBindings form (no actions, no
# POST from the reactive controller: the system spec's fetch spy proves it):
# typing is remembered across a reload, a reactive_show section re-evaluates
# from the restored value on first paint, the honeypot / hidden / password
# controls never reach storage, a "Next step" click writes a state bag via
# js.persist_state, "Discard" forgets via js.persist_clear, and a successful
# Turbo form submit clears the draft automatically.
class PersistFormComponent < ApplicationComponent
  include Phlex::Reactive::ClientBindings

  reactive_scope :apply

  # storage: :session (issue #397) keeps the SAME key in sessionStorage, so
  # the spec can prove the two stores never share a lookup.
  def initialize(name: nil, storage: :local)
    @name = name
    @storage = storage
  end

  def reactive_values = { size: nil }

  def view_template
    form(action: "/persist_form", method: "post", data: { testid: "form" }) do
      div(**mix(reactive_root(id: "persist-form"),
        reactive_persist(key: "dummy-apply", ttl: 1.hour, debounce: 100, storage: @storage))) do
        # A server-rendered value (?name=…) must WIN over the draft (restore: :blank).
        input(**reactive_field(:name, type: "text", value: @name, data: { testid: "name" }))
        textarea(**reactive_field(:bio, data: { testid: "bio" }))
        label do
          input(**reactive_field(:size, type: "radio", value: "s", data: { testid: "size-s" }))
          plain "Small"
        end
        label do
          input(**reactive_field(:size, type: "radio", value: "l", data: { testid: "size-l" }))
          plain "Large"
        end
        div(**reactive_show(if: { size: "l" }, data: { testid: "large-note" })) { "Large surcharge applies" }
        label do
          input(**reactive_field(:gift, type: "checkbox", data: { testid: "gift" }))
          plain "Gift"
        end
        # Never persisted: the honeypot (explicit skip), hidden, password.
        input(name: "fuckery", type: "text", data: { testid: "honeypot" }, **reactive_persist_skip)
        input(type: "hidden", name: "apply[tz]", value: "UTC", data: { testid: "tz" })
        input(**reactive_field(:secret, type: "password", data: { testid: "secret" }))

        button(**mix(on_client(:click, js.persist_state(step: 2)), data: { testid: "next" })) { "Next step" }
        button(**mix(on_client(:click, js.persist_clear), data: { testid: "discard" })) { "Discard" }
        button(type: "submit", data: { testid: "submit" }) { "Apply" }
      end
    end
  end
end
