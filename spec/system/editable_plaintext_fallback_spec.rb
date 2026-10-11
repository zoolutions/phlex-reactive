# frozen_string_literal: true

require "system_helper"

# Issue #355: in an engine without contenteditable="plaintext-only" the server's
# value is INVALID (the element cannot be focused), so the runtime switches every
# reactive editable to "true", however it reaches the page. Here a stream
# appends the root's first editable (no root re-render, no bindings yet).
#
# Chromium HAS plaintext-only, so an init script makes the client's probe see
# an engine without it: assigning "plaintext-only" throws, as it does in such
# an engine. Chromium still treats the server's attribute as valid, so this
# proves the switch and what follows it (the focus loads bindings, Enter is
# swallowed), not the dead field itself. The script only acts on a URL that
# carries ?plaintext_fallback, so a page the driver reuses is unaffected.
RSpec.describe "Editable text in an engine without plaintext-only (issue #355)", type: :system do
  def fallback_engine_script = <<~JS
    if (location.search.includes("plaintext_fallback")) {
      const real = Object.getOwnPropertyDescriptor(HTMLElement.prototype, "contentEditable")
      Object.defineProperty(HTMLElement.prototype, "contentEditable", {
        configurable: true,
        get: real.get,
        set(value) {
          if (value === "plaintext-only") throw new DOMException("invalid contentEditable", "SyntaxError")
          real.set.call(this, value)
        },
      })
    }
  JS

  let(:late) { find("[data-testid='late-title']") }

  before do
    page.driver.with_playwright_page { it.add_init_script(script: fallback_engine_script) }
    visit "/late_editable?plaintext_fallback=1"
  end

  it "switches a stream-appended editable to contenteditable=true, and its focus wires Enter" do
    find("[data-testid='add']").click
    expect(page).to have_css("[data-testid='late-title'][contenteditable='true']")

    late.click
    late.send_keys(" more")
    late.send_keys(:enter)
    expect(page.evaluate_script("document.querySelector(\"[data-testid='late-title']\").innerHTML")).to eq("Draft more")
  end
end
