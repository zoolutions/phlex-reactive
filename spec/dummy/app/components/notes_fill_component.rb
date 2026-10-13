# frozen_string_literal: true

# Issue #374: js.set_value — fill a field's live value from text already on
# the page, with no clipboard and no round trip. The "Thanks" button fills the
# notes textarea AND the hidden template key in one gesture; the bubbling
# `input` it dispatches drives the reactive_show bound to the hidden key, the
# way a typed value would. The other triggers cover the rest of the contract:
# HTML kept as characters, clearing, a select, a file input (only "" is
# accepted), a contenteditable (skipped), and set_attr("value") staying an
# attribute write. Declares NO actions: nothing is posted.
class NotesFillComponent < ApplicationComponent
  include Phlex::Reactive::Component

  def id = "notes-fill"

  # First paint: no template picked, so the reactive_show starts hidden.
  def reactive_values = { template_key: "" }

  def view_template
    div(**reactive_root) do
      triggers
      textarea(id: "notes", name: "notes", data: { testid: "notes" })
      input(id: "template_key", type: "hidden", name: "template_key")
      p(**reactive_show(if: { template_key: "thanks" }, data: { testid: "template-picked" })) do
        "Template: thanks"
      end
      select(id: "tone", name: "tone", data: { testid: "tone-select" }) do
        option(value: "formal") { "Formal" }
        option(value: "warm") { "Warm" }
      end
      select(id: "tags", name: "tags[]", multiple: true, data: { testid: "tags-select" }) do
        option(value: "a") { "A" }
        option(value: "b") { "B" }
        option(value: "c") { "C" }
      end
      input(id: "file", type: "file", name: "file", data: { testid: "file" })
      div(id: "body", contenteditable: "true", data: { testid: "body" }) { "Editable" }
    end
  end

  private

  def triggers
    trigger("fill", js.set_value("#notes", "Thanks for your order.").set_value("#template_key", "thanks"))
    trigger("html", js.set_value("#notes", "<b>bold</b>"))
    trigger("clear", js.set_value("#notes", nil))
    trigger("tone", js.set_value("#tone", "warm"))
    trigger("tags", js.set_value("#tags", "a"))
    trigger("file-bad", js.set_value("#file", "x"))
    trigger("file-clear", js.set_value("#file", ""))
    trigger("editable", js.set_value("#body", "x"))
    trigger("attr", js.set_attr("#notes", "value", "From the attribute"))
  end

  def trigger(testid, ops)
    button(type: "button", **mix(on_client(:click, ops), data: { testid: })) { testid }
  end
end
