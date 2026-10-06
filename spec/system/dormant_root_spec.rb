# frozen_string_literal: true

require "system_helper"

# Issue #274: a DORMANT root mounts the reactive controller on first use. The
# /dormant page's only reactive root renders data-reactive-dormant="reactive",
# and its layout loads the controller the way stimulus-loading's
# lazyLoadControllersFrom does — when an element first lists it in
# data-controller. So nothing reactive is fetched until a trigger fires;
# phlex/reactive/early (eager, ~1 KB) wakes the root and the trigger is
# replayed when the controller connects.
RSpec.describe "Dormant roots (issue #274 — mount the controller on first use)", type: :system do
  def action_posts = page.evaluate_script("window.__actionPosts")

  def controller_fetches
    page.evaluate_script(<<~JS)
      performance.getEntriesByType("resource")
        .filter((entry) => entry.name.includes("/vendor/reactive_controller.js") || entry.name.includes("/vendor/core.js")).length
    JS
  end

  def probe = page.evaluate_script("window.__probe")

  def open_panel
    page.execute_script(%(document.getElementById("dormant-panel").dispatchEvent(new CustomEvent("panel:opened"))))
  end

  def visit_dormant(load: "auto")
    visit "/dormant?load=#{load}"
    expect(page).to have_css("#dormant-panel[data-reactive-dormant='reactive']")
    expect(page.evaluate_script("window.__earlyReady === true")).to be(true)
  end

  # Settled, and nothing more in flight.
  def expect_action_posts(count)
    wait_for_reactive
    sleep 0.3
    expect(action_posts).to eq(count)
  end

  context "with a lazily loaded controller" do
    it "fetches no reactive client until a trigger fires, then makes exactly one request" do
      visit_dormant
      # Give a wrongly eager load every chance to show up.
      sleep 0.3
      expect(controller_fetches).to eq(0)
      expect(page).to have_css("[data-testid='connects']", exact_text: "0")
      expect(page).to have_no_css("#dormant-panel[data-controller~='reactive']")

      find("[data-testid='bump']").click

      expect(page).to have_css("[data-testid='clicks']", text: "1")
      expect(controller_fetches).to eq(1)
      expect_action_posts(1)
    end

    it "behaves like any root after the wake: one request per trigger, no second wake" do
      visit_dormant
      find("[data-testid='bump']").click
      expect(page).to have_css("[data-testid='clicks']", text: "1")

      # The reply REPLACED the root: the replacement is awake, not dormant.
      expect(page).to have_css("#dormant-panel[data-controller~='reactive']")
      expect(page).to have_no_css("[data-reactive-dormant]")

      reset_reactive_requests!
      find("[data-testid='bump']").click
      expect(page).to have_css("[data-testid='clicks']", text: "2")
      expect(page).to have_reactive_requests(1, kind: :action)
      expect_action_posts(2)
      expect(controller_fetches).to eq(1)
    end

    it "wakes on a custom event, replaying a :once trigger fired three times once" do
      visit_dormant
      3.times { open_panel }

      expect(page).to have_css("[data-testid='loads']", text: "1")
      expect_action_posts(1)
    end

    it "replays two triggers fired before connect in order, with one wake" do
      visit_dormant
      page.execute_script(<<~JS)
        const bump = document.querySelector("[data-testid='bump']")
        bump.click()
        bump.click()
      JS

      expect(page).to have_css("[data-testid='clicks']", text: "2")
      expect_action_posts(2)
      expect(controller_fetches).to eq(1)
    end

    it "keeps the root's other controller connected through the wake" do
      visit_dormant
      expect(probe).to eq("connects" => 1, "disconnects" => 0)

      open_panel
      # `load` replies with a morph: the same root element stays in place.
      expect(page).to have_css("[data-testid='loads']", text: "1")
      expect(page).to have_css("#dormant-panel[data-controller='probe reactive']")
      expect(probe).to eq("connects" => 1, "disconnects" => 0)
    end

    it "wakes again after a Turbo Drive visit, without re-fetching the client" do
      visit_dormant
      find("[data-testid='bump']").click
      expect(page).to have_css("[data-testid='clicks']", text: "1")

      page.execute_script("window.__marker = 'alive'")
      find("[data-testid='visit']").click
      expect(page).to have_css("[data-testid='clicks']", text: "0")
      expect(page.evaluate_script("window.__marker")).to eq("alive")
      expect(page).to have_css("#dormant-panel[data-reactive-dormant='reactive']")

      find("[data-testid='bump']").click
      expect(page).to have_css("[data-testid='clicks']", text: "1")
      expect_action_posts(2)
    end

    it "re-wakes on the next trigger when a morph renders the woken root dormant again" do
      visit_dormant
      find("[data-testid='bump']").click
      expect(page).to have_css("[data-testid='clicks']", text: "1")
      expect(page).to have_css("#dormant-panel[data-controller~='reactive']")
      wait_for_reactive

      # What a broadcast or a page refresh sends: the root rendered outside an
      # actor reply, so dormant, morphed over the live (awake) one.
      page.execute_script(<<~JS)
        fetch("/dormant_stream", { headers: { Accept: "text/vnd.turbo-stream.html" } })
          .then((response) => response.text())
          .then((html) => window.Turbo.renderStreamMessage(html))
      JS
      expect(page).to have_css("[data-testid='clicks']", text: "7")
      expect(page).to have_css("#dormant-panel[data-reactive-dormant='reactive']")
      expect(page).to have_no_css("#dormant-panel[data-controller~='reactive']")

      find("[data-testid='bump']").click
      expect(page).to have_css("[data-testid='clicks']", text: "8")
      expect_action_posts(2)
    end
  end

  # reactive_lazy(on:) + reactive_dormant (issues #276 + #274): "load this panel
  # the first time it opens, and do not fetch the controller until then".
  context "with a dormant reactive_lazy(on:) event shell" do
    def open_lazy_panel
      page.execute_script(
        %(document.getElementById("dormant-lazy-panel").dispatchEvent(new CustomEvent("panel:opened")))
      )
    end

    it "fetches nothing until the event, then wakes and materializes exactly once" do
      visit "/dormant_lazy"
      expect(page).to have_css("#dormant-lazy-panel[data-reactive-dormant='reactive']")
      expect(page).to have_css("[data-testid='panel-skeleton']")
      expect(page.evaluate_script("window.__earlyReady === true")).to be(true)
      sleep 0.3
      expect(controller_fetches).to eq(0)
      expect(action_posts).to eq(0)

      2.times { open_lazy_panel }

      expect(page).to have_css("[data-testid='panel-item']", text: "item:mine")
      # The real content arrived awake: no second wake is needed.
      expect(page).to have_css("#dormant-lazy-panel[data-controller~='reactive']")
      expect(page).to have_no_css("[data-reactive-dormant]")
      open_lazy_panel
      expect_action_posts(1)
      expect(controller_fetches).to eq(1)
    end
  end

  # A dormant morph-back DISCONNECTS the root (unlike a morph reply), so a :once
  # trigger that was already replayed must be usable again after the re-wake.
  context "when a :once trigger was replayed before the root went back to sleep" do
    def morph_with(html_js)
      page.execute_script(<<~JS)
        window.Turbo.renderStreamMessage(
          '<turbo-stream action="replace" method="morph" target="' + #{html_js}.id + '"><template>' +
            #{html_js}.html + "</template></turbo-stream>"
        )
      JS
    end

    it "fires again on a plain dormant root" do
      visit_dormant
      open_panel
      expect(page).to have_css("[data-testid='loads']", text: "1")
      wait_for_reactive

      page.execute_script(<<~JS)
        fetch("/dormant_stream", { headers: { Accept: "text/vnd.turbo-stream.html" } })
          .then((response) => response.text())
          .then((html) => window.Turbo.renderStreamMessage(html))
      JS
      expect(page).to have_css("[data-testid='clicks']", text: "7")
      expect(page).to have_css("#dormant-panel[data-reactive-dormant='reactive']")
      expect(page).to have_css("[data-testid='loads']", text: "0")

      3.times { open_panel }
      # Exactly one more request. (Not asserting the count it renders: after a
      # morph REPLY the controller keeps using its cached token rather than the
      # one an outside morph brought, on any root — a separate, older matter.)
      expect(page).to have_no_css("[data-testid='loads']", exact_text: "0")
      expect_action_posts(2)
    end

    it "retries a dormant reactive_lazy(on:) shell whose first load failed" do
      visit "/dormant_lazy?scope=forbidden"
      expect(page).to have_css("#dormant-lazy-panel[data-reactive-dormant='reactive']")
      expect(page.evaluate_script("window.__earlyReady === true")).to be(true)
      # A shell the server WILL render, fetched without visiting.
      page.execute_script(<<~JS)
        fetch("/dormant_lazy").then((r) => r.text()).then((html) => {
          const el = new DOMParser().parseFromString(html, "text/html").getElementById("dormant-lazy-panel")
          window.__freshShell = { id: el.id, html: el.outerHTML }
          document.documentElement.setAttribute("data-fresh-shell", "ready")
        })
      JS
      expect(page).to have_css("html[data-fresh-shell='ready']")

      page.execute_script(%(document.getElementById("dormant-lazy-panel").dispatchEvent(new CustomEvent("panel:opened"))))
      expect(page).to have_css("#dormant-lazy-panel[data-reactive-error]")
      expect_action_posts(1)

      morph_with("window.__freshShell")
      expect(page).to have_css("#dormant-lazy-panel[data-reactive-dormant='reactive']")

      3.times do
        page.execute_script(
          %(document.getElementById("dormant-lazy-panel").dispatchEvent(new CustomEvent("panel:opened")))
        )
      end
      expect(page).to have_css("[data-testid='panel-item']", text: "item:mine")
      expect_action_posts(2)
    end
  end

  context "with an eagerly registered controller" do
    it "does not connect the dormant root on load, and handles the waking click once" do
      visit_dormant(load: "eager")
      expect(controller_fetches).to eq(1)
      expect(page).to have_css("[data-testid='connects']", exact_text: "0")

      # A real click: the root wakes in the capture phase and Stimulus connects
      # it before the click reaches the listener it binds — replayed once, not
      # dispatched a second time by that listener.
      find("[data-testid='bump']").click

      expect(page).to have_css("[data-testid='clicks']", text: "1")
      expect_action_posts(1)
      expect(page).to have_css("[data-testid='clicks']", exact_text: "1")
    end
  end

  # Issue #303: a window-bound hotkey, pressed anywhere on the page, wakes the
  # root and is replayed once — under both registrations (eager: the root
  # connects while the keypress is still propagating to Stimulus's freshly
  # bound window listener, which must not run it again).
  context "with a window-bound hotkey" do
    def expect_one_request_on_hotkey(load:, fetched_before:)
      visit_dormant(load:)
      sleep 0.3
      expect(controller_fetches).to eq(fetched_before)
      expect(page).to have_css("[data-testid='connects']", exact_text: "0")

      find("body").send_keys("k")

      expect(page).to have_css("[data-testid='clicks']", text: "1")
      expect(page).to have_css("#dormant-panel[data-controller~='reactive']")
      expect(controller_fetches).to eq(1)
      expect_action_posts(1)
      expect(page).to have_css("[data-testid='clicks']", exact_text: "1")
    end

    it "wakes the root and makes exactly one request (lazily loaded controller)" do
      expect_one_request_on_hotkey(load: "auto", fetched_before: 0)
    end

    it "wakes the root and makes exactly one request (eagerly registered controller)" do
      expect_one_request_on_hotkey(load: "eager", fetched_before: 1)
    end

    it "behaves like any trigger after the wake" do
      visit_dormant
      find("body").send_keys("k")
      expect(page).to have_css("[data-testid='clicks']", text: "1")
      wait_for_reactive

      find("body").send_keys("k")
      expect(page).to have_css("[data-testid='clicks']", text: "2")
      expect_action_posts(2)
    end
  end

  # Two roots sharing one hotkey (issue #303): each hears a press exactly once,
  # and a root's replay never swallows its sibling's live firing — under both
  # registrations, with both roots dormant and with one already awake.
  context "with two roots sharing a window-bound hotkey" do
    def visit_pair(dormant:, load:)
      visit "/hotkey_pair?dormant=#{dormant}&load=#{load}"
      expect(page).to have_css("[data-testid='root-second'][data-reactive-dormant='reactive']")
      expect(page.evaluate_script("window.__earlyReady === true")).to be(true)
      # An awake first root connects on load under either registration.
      expect(page).to have_css("[data-testid='connects']", exact_text: dormant == "second" ? "1" : "0")
    end

    def expect_keys(first, second)
      expect(page).to have_css("[data-testid='keys-first']", exact_text: first.to_s)
      expect(page).to have_css("[data-testid='keys-second']", exact_text: second.to_s)
    end

    # One press before connect: each root exactly once, no swallow of the
    # sibling's firing; a later press is normal for both.
    def expect_each_root_once(dormant:, load:)
      visit_pair(dormant:, load:)

      find("body").send_keys("k")

      expect_keys(1, 1)
      expect(page).to have_css("[data-testid='root-first'][data-controller~='reactive']")
      expect(page).to have_css("[data-testid='root-second'][data-controller~='reactive']")
      expect(controller_fetches).to eq(1)
      expect_action_posts(2)
      expect_keys(1, 1)

      find("body").send_keys("k")
      expect_keys(2, 2)
      expect_action_posts(4)
    end

    it "one press reaches each root once with both dormant (lazily loaded controller)" do
      expect_each_root_once(dormant: "both", load: "auto")
    end

    it "one press reaches each root once with both dormant (eagerly registered controller)" do
      expect_each_root_once(dormant: "both", load: "eager")
    end

    it "one press reaches the awake root live and the dormant one by replay (lazily loaded controller)" do
      expect_each_root_once(dormant: "second", load: "auto")
    end

    it "one press reaches the awake root live and the dormant one by replay (eagerly registered controller)" do
      expect_each_root_once(dormant: "second", load: "eager")
    end

    it "three presses before connect wake both roots once and replay in order" do
      visit_pair(dormant: "both", load: "auto")
      page.execute_script(<<~JS)
        for (let i = 0; i < 3; i++) {
          document.body.dispatchEvent(new KeyboardEvent("keydown", { key: "k", bubbles: true, cancelable: true }))
        }
      JS

      expect_keys(3, 3)
      expect(controller_fetches).to eq(1)
      expect_action_posts(6)
    end

    it "replays a :once hotkey once, and its still-armed listener does not fire it again" do
      visit_pair(dormant: "both", load: "auto")
      page.execute_script(<<~JS)
        for (let i = 0; i < 2; i++) {
          document.body.dispatchEvent(new KeyboardEvent("keydown", { key: "o", bubbles: true, cancelable: true }))
        }
      JS

      expect(page).to have_css("[data-testid='onces-first']", exact_text: "1")
      expect_action_posts(1)

      # The reply MORPHED the root, so Stimulus's own `once` listener for the
      # replayed hotkey is still armed: its one firing must be swallowed, and
      # the other hotkey on the same root must still work.
      find("body").send_keys("o")
      find("body").send_keys("k")
      expect_keys(1, 1)
      expect_action_posts(3)
      expect(page).to have_css("[data-testid='onces-first']", exact_text: "1")
    end
  end
end
