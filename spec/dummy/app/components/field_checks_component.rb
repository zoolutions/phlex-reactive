# frozen_string_literal: true

# Show conditions that read more than one literal (issues #395, #396, #394):
# a Save button enabled only while the confirmation matches the email
# (same:, case-folded), and a hint shown while they differ; a code hint that
# waits for the field's first blur (digits:, starts_with:, after:). Declares
# NO actions: nothing is posted.
class FieldChecksComponent < ApplicationComponent
  include Phlex::Reactive::Component

  def id = "field-checks"

  def reactive_values = { email: "", confirm_email: "", code: "" }

  def view_template
    div(**reactive_root) do
      email_match
      code_format
    end
  end

  private

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
