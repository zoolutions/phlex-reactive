# frozen_string_literal: true

# Show conditions that read more than one literal (issues #395, #396, #394):
# a Save button enabled only while the confirmation matches the email
# (same:, case-folded), and a hint shown while they differ. Declares NO
# actions: nothing is posted.
class FieldChecksComponent < ApplicationComponent
  include Phlex::Reactive::Component

  def id = "field-checks"

  def reactive_values = { email: "", confirm_email: "" }

  def view_template
    div(**reactive_root) do
      email_match
    end
  end

  private

  def email_match
    input(name: "email", type: "email", data: { testid: "email" })
    input(name: "confirm_email", type: "email", data: { testid: "confirm-email" })
    button(type: "button", **reactive_enable(if: { confirm_email: { same: :email, case: :fold } },
      data: { testid: "save" })) { "Save" }
    p(**reactive_show(unless: { confirm_email: { same: :email, case: :fold } },
      data: { testid: "differ" })) { "The addresses differ" }
  end
end
