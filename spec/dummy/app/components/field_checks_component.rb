# frozen_string_literal: true

# Show conditions that read more than one literal (issues #395, #396, #394):
# a Save button enabled only while the confirmation matches the email
# (same:, case-folded), and a hint shown while they differ; a code hint that
# waits for the field's first blur (digits:, starts_with:, after:); a section
# that clears its fields when it hides and focuses + scrolls when it shows
# (clear:, focus:, scroll:). Declares NO actions: nothing is posted.
class FieldChecksComponent < ApplicationComponent
  include Phlex::Reactive::Component

  def id = "field-checks"

  def reactive_values = { email: "", confirm_email: "", code: "", kind: "listed" }

  def view_template
    div(**reactive_root) do
      email_match
      code_format
      other_notes
    end
  end

  private

  # clear:/focus:/scroll: on a visibility change (issue #394). The spacer
  # pushes the section below the fold, so scroll: has something to do.
  def other_notes
    input(type: "radio", name: "kind", value: "listed", checked: true, data: { testid: "kind-listed" })
    input(type: "radio", name: "kind", value: "other", data: { testid: "kind-other" })
    div(style: "height: 2000px", data: { testid: "spacer" })
    div(**reactive_show(if: { kind: "other" }, clear: %i[notes urgent], focus: "#notes", scroll: true,
      data: { testid: "other-section" })) do
      # A value the server rendered into the hidden section: first paint keeps it.
      input(id: "notes", name: "notes", value: "saved", data: { testid: "notes" })
      input(type: "checkbox", name: "urgent", checked: true, data: { testid: "urgent" })
    end
  end

  # digits: + starts_with: (issue #396), quiet until the field has blurred.
  def code_format
    input(name: "code", inputmode: "numeric", data: { testid: "code" })
    p(**reactive_show(unless: { code: { digits: 10, starts_with: "9" } }, after: :blur,
      data: { testid: "code-hint" })) { "Enter 10 digits starting with 9" }
    p(**reactive_show(if: { code: { digits: 9..11 } }, data: { testid: "code-ok" })) { "Looks like a code" }
  end

  def email_match
    input(name: "email", type: "email", data: { testid: "email" })
    input(name: "confirm_email", type: "email", data: { testid: "confirm-email" })
    button(type: "button", **reactive_enable(if: { confirm_email: { same: :email, case: :fold } },
      data: { testid: "save" })) { "Save" }
    p(**reactive_show(unless: { confirm_email: { same: :email, case: :fold } },
      data: { testid: "differ" })) { "The addresses differ" }
  end
end
