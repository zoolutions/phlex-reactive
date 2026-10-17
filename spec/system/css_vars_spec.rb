# frozen_string_literal: true

require "system_helper"

# Issue #417: reactive_css_vars feeds fields into CSS custom properties, so a
# preview follows its controls with no request. Asserted on the inline
# property AND on the computed style, which proves the browser applies it.
# Untagged, so it runs on both entries; `rake spec:system_split` lists it
# because the binding lives in the bindings feature module, which the opt-in
# client must load for a root whose only binding is this one.
RSpec.describe "CSS custom properties from fields (issue #417)", type: :system do
  def sample = find("[data-testid='sample']")

  def computed(property)
    page.evaluate_script("getComputedStyle(document.querySelector('[data-testid=sample]')).#{property}")
  end

  def inline(name)
    page.evaluate_script("document.querySelector('[data-testid=sample]').style.getPropertyValue('#{name}')")
  end

  # Waits until the sample's inline property reads `value` ("" = removed).
  def expect_property(name, value)
    page.document.synchronize do
      raise Capybara::ExpectationNotMet, "#{name} is #{inline(name).inspect}, expected #{value.inspect}" unless
        inline(name) == value
    end
  end

  def slide(times, key = :right)
    find("[data-testid='light']").send_keys(*Array.new(times, key))
  end

  def slider_value = find("[data-testid='light']").value

  context "when the page opens with the defaults" do
    before do
      visit "/css_vars"
      find("#css-vars-preview[data-reactive-connected]")
      reset_reactive_requests!
    end

    it "the slider and the select drive the sample's filter and rotation, with no request" do
      slide(2)
      expect_property("--light", "1.1")
      expect(computed("filter")).to eq("brightness(1.1)")

      slide(4, :left)
      expect_property("--light", "0.9")
      expect(computed("filter")).to eq("brightness(0.9)")

      find("[data-testid='turn']").select("90")
      expect_property("--turn", "90deg")
      expect(computed("rotate")).to eq("90deg")

      expect(page).to have_reactive_requests(0)
    end

    it "a checkbox gives 1 or 0, and a radio group its checked value" do
      expect_property("--framed", "0")
      # No radio is checked: the property is removed and var()'s fallback applies.
      expect_property("--gap", "")
      expect(computed("paddingTop")).to eq("4px")

      find("[data-testid='framed']").check
      expect_property("--framed", "1")
      expect(computed("outlineWidth")).to eq("2px")
      find("[data-testid='framed']").uncheck
      expect_property("--framed", "0")

      find("[data-testid='gap-8']").choose
      expect_property("--gap", "8px")
      expect(computed("paddingTop")).to eq("8px")
      find("[data-testid='gap-16']").choose
      expect_property("--gap", "16px")

      expect(page).to have_reactive_requests(0)
    end

    it "re-seeds after a morph that wrote the server's inline style back" do
      slide(3)
      expect_property("--light", "1.15")

      # Every style the sample is written over from now on (a record's oldValue:
      # the morph and the re-seed land in one task, so the callback only ever
      # sees the last), to prove the morph really wrote the server's value.
      page.execute_script(<<~JS)
        const sample = document.querySelector("[data-testid=sample]")
        const probe = document.createElement("div")
        window.__styles = []
        new MutationObserver((records) => {
          for (const record of records) {
            probe.setAttribute("style", record.oldValue ?? "")
            window.__styles.push(probe.style.getPropertyValue("--light"))
          }
        }).observe(sample, { attributeFilter: ["style"], attributeOldValue: true })
      JS
      # A click through script keeps the slider focused, so the morph keeps its
      # value (#338) while it writes the server's `--light: 1` onto the sample.
      page.execute_script("document.querySelector('[data-testid=save]').click()")
      expect(page).to have_css("[data-testid='saves']", text: "1")

      expect(page.evaluate_script("window.__styles")).to include("1")
      expect(slider_value).to eq("1.15")
      expect_property("--light", "1.15")
      expect(computed("filter")).to eq("brightness(1.15)")
    end

    it "matches the slider again after a visit away and back" do
      slide(2)
      expect_property("--light", "1.1")

      find("[data-testid='away']").click
      expect(page).to have_current_path("/counter")
      page.go_back
      find("#css-vars-preview[data-reactive-connected]")

      expect_property("--light", slider_value)
    end
  end

  it "corrects a first paint that differs from the field on connect" do
    visit "/css_vars?light=1.3"
    find("#css-vars-preview[data-reactive-connected]")

    expect_property("--light", "1.3")
    expect(computed("filter")).to eq("brightness(1.3)")
  end
end
