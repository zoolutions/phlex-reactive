# frozen_string_literal: true

require "system_helper"

# Issue #452: reactive_image_fallback inside a Turbo frame. Turbo imports the
# fetched frame into the document (document.importNode) and inserts it a few
# awaits later; an img starts loading once imported, so one whose request ends
# in that gap fires `error`/`load` on a DETACHED node, which the runtime's
# document listener cannot hear. The runtime reads the result off the element
# once Turbo has inserted the frame (turbo:frame-render) or the page
# (turbo:render). Untagged: both entries share the runtime this lives in.
RSpec.describe "Image fallback in a Turbo frame (issue #452)", type: :system do
  let(:missing_logos) { (1..ImageFallbackFrameComponent::MISSING).map { "/logos/missing-#{it}.svg" } }

  def img(testid, extra = "") = "[data-testid='#{testid}']#{extra}"

  def expect_every_missing_logo_hidden
    expect(page).to have_css("turbo-frame#logos #{img("logos")}")
    expect(page).to have_css(img("fine", "[data-reactive-image-state='loaded']:not([hidden])"))
    (1..ImageFallbackFrameComponent::MISSING).each do
      expect(page).to have_css(img("missing-#{it}", "[data-reactive-image-state='error'][hidden]"), visible: :all)
    end
    expect(page).to have_no_css("img[data-reactive-image-fallback]:not([data-reactive-image-state])", visible: :all)
  end

  before do
    visit "/image_fallback_frame"
    find(img("open"))
  end

  it "marks and hides every img whose request ended before the frame was inserted, with no second request" do
    requests = Hash.new(0)
    logos = missing_logos
    count = -> { requests[URI(it.url).path] += 1 if logos.include?(URI(it.url).path) }
    page.driver.with_playwright_page { it.on("request", count) }
    # Hold Turbo's frame render until every img of the imported, still
    # detached frame has finished: each one's event fires before it is in the
    # document — the gap the race lands in, made certain.
    page.execute_script(<<~JS)
      document.addEventListener("turbo:before-frame-render", (event) => {
        event.preventDefault()
        const imgs = [...event.detail.newFrame.querySelectorAll("img")]
        const wait = () => {
          if (!imgs.every((img) => img.complete)) return setTimeout(wait, 10)
          window.__finishedDetached = imgs.length > 0 && imgs.every((img) => !img.isConnected)
          event.detail.resume()
        }
        wait()
      }, { once: true })
    JS

    find(img("open")).click

    expect_every_missing_logo_hidden
    expect(page.evaluate_script("window.__finishedDetached")).to be(true)
    expect(requests).to eq(missing_logos.to_h { [it, 1] })
  ensure
    page.driver.with_playwright_page { it.off("request", count) }
  end

  it "a page render marks every img whose request ended before the new body was inserted" do
    # A custom page render (an app animating its swaps) inserts Turbo's
    # adopted, still detached body only once its imgs have finished.
    page.execute_script(<<~JS)
      document.addEventListener("turbo:before-render", (event) => {
        event.detail.render = async (currentBody, newBody) => {
          const imgs = [...newBody.querySelectorAll("img")]
          while (!imgs.every((img) => img.complete)) await new Promise((resolve) => setTimeout(resolve, 10))
          window.__finishedDetached = imgs.length > 0 && imgs.every((img) => !img.isConnected)
          currentBody.replaceWith(newBody)
        }
      }, { once: true })
      Turbo.visit("/image_fallback_frame?open=1")
    JS

    expect_every_missing_logo_hidden
    expect(page.evaluate_script("window.__finishedDetached")).to be(true)
  end

  it "the issue's reproduction: logo requests fail fast and the frame renders unheld" do
    page.driver.with_playwright_page { it.route("**/logos/missing-*", ->(route, _request) { route.abort }) }

    find(img("open")).click

    expect_every_missing_logo_hidden
  ensure
    page.driver.with_playwright_page { it.unroute("**/logos/missing-*") }
  end
end
