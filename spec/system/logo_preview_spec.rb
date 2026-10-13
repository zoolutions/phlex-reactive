# frozen_string_literal: true

require "system_helper"

# Issue #373: js.copy_media and reactive_media copy an image the SERVER
# rendered onto a preview, with no URL in any op or binding attribute — the
# set_attr refusal of src (issue #96) stays. Untagged, so it runs on both
# entries; `rake spec:system_split` lists it because the binding lives in the
# bindings feature module, which the opt-in client must load for a root whose
# only binding is a media one.
RSpec.describe "Media previews (issue #373)", type: :system do
  # The attribute's value, or nil when it is absent.
  def attr(testid, name)
    value = page.evaluate_script(
      "document.querySelector('[data-testid=#{testid}]').getAttribute('#{name}') ?? '(absent)'"
    )
    value == "(absent)" ? nil : value
  end

  # Count src/srcset writes on an element from now on.
  def watch_writes(testid)
    page.execute_script(<<~JS)
      window.__writes = 0
      new MutationObserver((records) => { window.__writes += records.length })
        .observe(document.querySelector("[data-testid=#{testid}]"), { attributeFilter: ["src", "srcset"] })
    JS
  end

  def writes = page.evaluate_script("window.__writes")

  def type_code(value)
    find("[data-testid='code']").fill_in(with: value)
  end

  before do
    visit "/logo_preview"
    find("#logo-preview[data-reactive-connected]")
  end

  it "reactive_media copies the pool image whose key is the field's prefix, and clears on a miss" do
    type_code("007-42")
    expect(page).to have_css("[data-testid='preview'][src='/logos/007.svg'][srcset='/logos/007.svg 1x'][alt='North']")
    expect(page).to have_css("[data-testid='caption']", text: "North")
    expect(page.evaluate_script("document.querySelector('[data-testid=preview]').complete")).to be(true)

    type_code("011")
    expect(page).to have_css("[data-testid='preview'][src='/logos/011.svg'][alt='South']")
    expect(attr("preview", "srcset")).to be_nil

    type_code("123")
    expect(page).to have_css("[data-testid='caption']", text: "Unknown")
    expect(attr("preview", "src")).to be_nil
    expect(attr("preview", "alt")).to eq("")
  end

  it "re-typing within the same key does not write src again" do
    type_code("007")
    expect(page).to have_css("[data-testid='preview'][src='/logos/007.svg']")
    watch_writes("preview")

    find("[data-testid='code']").send_keys("1", "2")
    expect(find("[data-testid='code']").value).to eq("00712")
    expect(writes).to eq(0)
  end

  it "a pool value that is a URL is only ever a selector: the preview clears" do
    type_code("007")
    expect(page).to have_css("[data-testid='preview'][src='/logos/007.svg']")

    type_code("999")
    expect(page).to have_css("[data-testid='caption']", text: "Unknown")
    expect(attr("preview", "src")).to be_nil
    expect(page).to have_no_css("[src*='example.test']", visible: :all)
  end

  it "a pool selector that is not an img clears the preview" do
    type_code("007")
    expect(page).to have_css("[data-testid='preview'][src='/logos/007.svg']")

    type_code("spa")
    expect(page).to have_css("[data-testid='caption']", text: "Unknown")
    expect(attr("preview", "src")).to be_nil
  end

  it "js.copy_media copies src, srcset and alt, writes nothing for the same URL, and clears on a missing source" do
    find("[data-testid='use-north']").click
    expect(page).to have_css("[data-testid='copied'][src='/logos/007.svg'][srcset='/logos/007.svg 1x'][alt='North']")

    watch_writes("copied")
    find("[data-testid='use-north']").click
    find("[data-testid='use-south']").click
    expect(page).to have_css("[data-testid='copied'][src='/logos/011.svg'][alt='South']")
    expect(writes).to eq(2) # srcset removed + src set: the repeat North click wrote nothing

    find("[data-testid='use-none']").click
    expect(page).to have_css("[data-testid='copied'][alt='']:not([src])")
  end

  it "js.copy_media never gives an iframe a src" do
    find("[data-testid='use-frame']").click
    find("[data-testid='use-north']").click # the chain after it still runs
    expect(page).to have_css("[data-testid='copied'][src='/logos/007.svg']")
    expect(attr("frame", "src")).to be_nil
  end
end
