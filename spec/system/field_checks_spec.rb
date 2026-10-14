# frozen_string_literal: true

require "system_helper"

# Show conditions that read more than one literal, in a real browser: same:
# (issue #395). Untagged, so it runs on both client entries; the show
# evaluator lives in the bindings feature module.
RSpec.describe "Field checks (issues #394-#396)", type: :system do
  def tid(name) = "[data-testid='#{name}']"

  before do
    visit "/field_checks"
    find("#field-checks[data-reactive-connected]")
  end

  describe "same: (issue #395)" do
    it "enables Save only while the confirmation matches the email, folding ASCII case" do
      expect(page).to have_css("#{tid("save")}:not([disabled])")
      expect(page).to have_css(tid("differ"), visible: :hidden)

      find(tid("email")).fill_in(with: "user@example.test")
      expect(page).to have_css("#{tid("save")}[disabled]")
      expect(page).to have_css(tid("differ"), text: "The addresses differ")

      find(tid("confirm-email")).fill_in(with: "USER@Example.test")
      expect(page).to have_css("#{tid("save")}:not([disabled])")
      expect(page).to have_css(tid("differ"), visible: :hidden)
    end
  end
end
