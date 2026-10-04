# frozen_string_literal: true

require "system_helper"

# reactive_lazy(on:) in a real browser (issue #276): the shell makes NO
# request on page load. An event-triggered shell materializes exactly once
# when its event reaches it (a later event finds the real render, which has no
# trigger); a :visible shell below the fold materializes only after scrolling.
#
# Turbo morphs keep the root CONNECTED (no Stimulus lifecycle), so the client
# handles them itself: real content morphed back into a shell re-materializes
# at once, a still-unloaded shell is re-armed (a failed load's retry path), and
# a morph that leaves real content real requests nothing.
RSpec.describe "reactive_lazy(on:) (issue #276)", type: :system do
  # Resource Timing covers the page load itself (the request counter starts
  # with the client). Valid here because every example starts with a full visit.
  def reactive_resources_on_load
    page.evaluate_script(<<~JS)
      performance.getEntriesByType("resource").filter((e) => e.name.includes("/reactive/")).length
    JS
  end

  def fire_panel_opened
    page.execute_script(%(document.getElementById("lazy-panel").dispatchEvent(new CustomEvent("panel:opened"))))
  end

  # Remember a root's current markup (the page-shipped shell, or the real render).
  def snapshot(id, as:)
    page.execute_script("window.__snapshots ??= {}; window.__snapshots[#{as.to_json}] = " \
                        "document.getElementById(#{id.to_json}).outerHTML")
  end

  # Morph a root to a remembered snapshot, the way a Turbo page refresh or a
  # morphing stream would: same element, attributes and children rewritten.
  def morph_to(id, snapshot:)
    page.execute_script(<<~JS)
      window.Turbo.renderStreamMessage(
        '<turbo-stream action="replace" method="morph" target=#{id.to_json}><template>' +
          window.__snapshots[#{snapshot.to_json}] + "</template></turbo-stream>"
      )
    JS
  end

  # The page-shipped shell of /lazy_on (scope "mine"), fetched without visiting.
  def snapshot_fresh_panel_shell
    page.execute_script(<<~JS)
      window.__snapshots ??= {}
      window.__shellReady = fetch("/lazy_on").then((r) => r.text()).then((html) => {
        const doc = new DOMParser().parseFromString(html, "text/html")
        window.__snapshots.freshShell = doc.getElementById("lazy-panel").outerHTML
        document.documentElement.setAttribute("data-fresh-shell", "ready")
      })
    JS
    expect(page).to have_css("html[data-fresh-shell='ready']")
  end

  def same_node_marker(id)
    page.execute_script(%(document.getElementById(#{id.to_json}).__same = "yes"))
  end

  def same_node?(id)
    page.evaluate_script(%(document.getElementById(#{id.to_json}).__same)) == "yes"
  end

  it "an event shell requests nothing until the event, then exactly once" do
    visit "/lazy_on"
    page.execute_script("window.__noReload = 'alive'")

    expect(page).to have_css("[data-testid='panel-skeleton']")
    expect(reactive_resources_on_load).to eq(0)
    expect(page).to have_reactive_requests(0)
    expect(page).to have_css("[data-testid='panel-skeleton']")

    fire_panel_opened
    expect(page).to have_css("[data-testid='panel-item']", text: "item:mine")
    expect(page).to have_no_css("[data-testid='panel-skeleton']")
    expect(page).to have_reactive_requests(1, kind: :action)

    # The real render carries no trigger: a second event is a no-op.
    fire_panel_opened
    expect(page).to have_reactive_requests(1)
    expect(page.evaluate_script("window.__noReload")).to eq("alive")

    # …and it arrived as a live reactive root with a fresh token.
    token = page.evaluate_script(%(document.getElementById("lazy-panel").getAttribute("data-reactive-token-value")))
    expect(token.to_s.length).to be > 20
  end

  it "a bubbling event from inside the shell counts" do
    visit "/lazy_on"

    page.execute_script(<<~JS)
      document.querySelector("[data-testid='panel-skeleton']")
        .dispatchEvent(new CustomEvent("panel:opened", { bubbles: true }))
    JS
    expect(page).to have_css("[data-testid='panel-item']", text: "item:mine")
    expect(page).to have_reactive_requests(1)
  end

  it "a :visible shell below the fold requests only after it scrolls into view" do
    visit "/lazy_on"

    expect(page).to have_css("[data-testid='fold-skeleton']", visible: :all)
    expect(reactive_resources_on_load).to eq(0)
    expect(page).to have_reactive_requests(0)

    page.execute_script(%(document.getElementById("lazy-fold").scrollIntoView()))
    expect(page).to have_css("[data-testid='fold-value']", text: "loaded:below")
    expect(page).to have_reactive_requests(1)

    page.execute_script("window.scrollTo(0, 0)")
    page.execute_script(%(document.getElementById("lazy-fold").scrollIntoView()))
    expect(page).to have_reactive_requests(1)
  end

  describe "after a Turbo morph (the root stays connected)" do
    it "an event shell's real content morphed back into the shell re-materializes — one request" do
      visit "/lazy_on"
      snapshot("lazy-panel", as: "shell")
      fire_panel_opened
      expect(page).to have_css("[data-testid='panel-item']", text: "item:mine")

      reset_reactive_requests!
      morph_to("lazy-panel", snapshot: "shell")

      # No event fires again (the panel is already open): the client reloads it.
      expect(page).to have_css("[data-testid='panel-item']", text: "item:mine")
      expect(page).to have_no_css("[data-testid='panel-skeleton']")
      expect(page).to have_reactive_requests(1)
    end

    it "a :visible shell's real content morphed back into the shell re-materializes — one request" do
      visit "/lazy_on"
      snapshot("lazy-fold", as: "shell")
      page.execute_script(%(document.getElementById("lazy-fold").scrollIntoView()))
      expect(page).to have_css("[data-testid='fold-value']", text: "loaded:below")

      reset_reactive_requests!
      morph_to("lazy-fold", snapshot: "shell")

      expect(page).to have_css("[data-testid='fold-value']", text: "loaded:below")
      expect(page).to have_no_css("[data-testid='fold-skeleton']", visible: :all)
      expect(page).to have_reactive_requests(1)
    end

    it "a morph that leaves real content as real content requests nothing" do
      visit "/lazy_on"
      fire_panel_opened
      expect(page).to have_css("[data-testid='panel-item']", text: "item:mine")
      snapshot("lazy-panel", as: "real")

      reset_reactive_requests!
      morph_to("lazy-panel", snapshot: "real")

      expect(page).to have_css("[data-testid='panel-item']", text: "item:mine")
      expect(page).to have_reactive_requests(0)
    end

    it "a failed load is not retried by itself, and is retried by its event after a morph" do
      visit "/lazy_on?scope=forbidden"
      snapshot_fresh_panel_shell

      fire_panel_opened
      expect(page).to have_css("#lazy-panel[data-reactive-error='http']")
      expect(page).to have_reactive_requests(1)
      expect(page).to have_css("[data-testid='panel-skeleton']")

      # The once-bound trigger is spent: the event alone does nothing.
      reset_reactive_requests!
      fire_panel_opened
      expect(page).to have_reactive_requests(0)

      # A morph (here: to a shell the server WILL render) re-arms the same node.
      same_node_marker("lazy-panel")
      morph_to("lazy-panel", snapshot: "freshShell")
      expect(page).to have_css("#lazy-panel[data-reactive-lazy-on]")
      expect(same_node?("lazy-panel")).to be(true)
      expect(page).to have_reactive_requests(0)

      fire_panel_opened
      expect(page).to have_css("[data-testid='panel-item']", text: "item:mine")
      expect(page).to have_reactive_requests(1)
    end
  end
end
