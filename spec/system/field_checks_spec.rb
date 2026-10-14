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

  describe "digits: + after: :blur (issue #396)" do
    it "keeps the hint hidden while typing, shows it on blur, then tracks every input" do
      code = find(tid("code"))
      code.fill_in(with: "12")
      expect(page).to have_css(tid("code-hint"), visible: :hidden)

      find(tid("email")).click # blur the code field
      expect(page).to have_css(tid("code-hint"), text: "Enter 10 digits")

      code.fill_in(with: "9123456789")
      expect(page).to have_css(tid("code-hint"), visible: :hidden)
      expect(page).to have_css(tid("code-ok"), text: "Looks like a code")

      code.fill_in(with: "912345678a")
      expect(page).to have_css(tid("code-hint"), text: "Enter 10 digits")
      expect(page).to have_css(tid("code-ok"), visible: :hidden)
    end
  end
end
