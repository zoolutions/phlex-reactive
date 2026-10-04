# frozen_string_literal: true

require "system_helper"

# reactive_lazy(cache:) in a real browser (issue #277): the real render is a
# GET the browser may keep privately, so it is REUSED instead of re-requested.
#
# "Reused" is asserted two ways: Resource Timing (a fetch the HTTP cache
# answered has transferSize 0) and the server's own render count. The request
# counter (have_reactive_requests) counts fetch() CALLS — a cache hit still
# counts there, as kind :defer.
#
# Two fixtures, the two ways another viewer is kept out of a cached copy:
#   * /cached_menu  — reactive_cache_viewer keys the URL on the viewer, so the
#     copy survives across page views (the session cookie may change freely).
#   * /cached_panel — the default, `Vary: Cookie`: reused while the cookie is
#     unchanged (a morph in the same page), re-requested once it changes.
RSpec.describe "reactive_lazy(cache:) (issue #277)", type: :system do
  # This page's fragment fetches, oldest first: bytes off the network (0 = the
  # browser's HTTP cache answered) and the URL.
  def fragment_fetches
    page.evaluate_script(<<~JS)
      performance.getEntriesByType("resource")
        .filter((e) => e.name.includes("/reactive/fragment/"))
        .map((e) => ({ transferSize: e.transferSize, url: e.name }))
    JS
  end

  def network_fetches = fragment_fetches.reject { it["transferSize"].zero? }

  def cache_hits = fragment_fetches.select { it["transferSize"].zero? }

  def view_as(viewer)
    visit "/cached_menu" if page.current_path.blank?
    if viewer
      page.execute_script("document.cookie = 'viewer=#{viewer}; path=/'")
    else
      page.execute_script("document.cookie = 'viewer=; path=/; max-age=0'")
    end
  end

  def fire_panel_opened
    page.execute_script(%(document.getElementById("cached-panel").dispatchEvent(new CustomEvent("panel:opened"))))
  end

  around do
    CachedMenuComponent.version = nil
    CachedMenuComponent.renders = 0
    it.run
  ensure
    CachedMenuComponent.version = nil
  end

  describe "a viewer-keyed fragment (reactive_cache_viewer)" do
    it "is fetched on the first page view and reused, with no request, on the next" do
      visit "/cached_menu"
      expect(page).to have_css("[data-testid='menu-item']", text: "menu:main:guest")
      expect(network_fetches.size).to eq(1)
      expect(CachedMenuComponent.renders).to eq(1)

      visit "/cached_menu"
      expect(page).to have_css("[data-testid='menu-item']", text: "menu:main:guest")

      expect(fragment_fetches.size).to eq(1)
      expect(cache_hits.size).to eq(1)
      expect(CachedMenuComponent.renders).to eq(1)
    end

    it "lands as a live reactive root, and counts the cache hit as a defer request" do
      visit "/cached_menu"
      expect(page).to have_css("[data-testid='menu-item']")
      visit "/cached_menu"

      expect(page).to have_css("#cached-menu[data-controller~='reactive'][data-reactive-token-value]")
      expect(page).to have_no_css("#cached-menu[data-reactive-defer-pending]")
      expect(page).to have_reactive_requests(1, kind: :defer)
      expect(page).to have_reactive_requests(0, kind: :action)
    end

    it "is requested again once reactive_cache_version changes the URL" do
      visit "/cached_menu"
      expect(page).to have_css("[data-testid='menu-item']")
      first_url = fragment_fetches.first["url"]

      CachedMenuComponent.version = "v2"
      visit "/cached_menu"
      expect(page).to have_css("[data-testid='menu-item']")

      expect(network_fetches.size).to eq(1)
      expect(fragment_fetches.first["url"]).not_to eq(first_url)
      expect(CachedMenuComponent.renders).to eq(2)
    end

    it "never shows one viewer's cached copy to another viewer of the same browser" do
      visit "/cached_menu"
      expect(page).to have_css("[data-testid='menu-item']", text: "menu:main:guest")

      view_as("alice")
      visit "/cached_menu"
      expect(page).to have_css("[data-testid='menu-item']", text: "menu:main:alice")
      expect(network_fetches.size).to eq(1)

      view_as(nil)
      visit "/cached_menu"
      expect(page).to have_css("[data-testid='menu-item']", text: "menu:main:guest")
      expect(page).to have_no_text("alice")
    end
  end

  describe "on: + cache: (load on first open)" do
    def snapshot(id, as:)
      page.execute_script("window.__snapshots ??= {}; window.__snapshots[#{as.to_json}] = " \
                          "document.getElementById(#{id.to_json}).outerHTML")
    end

    def morph_to(id, snapshot:)
      page.execute_script(<<~JS)
        window.Turbo.renderStreamMessage(
          '<turbo-stream action="replace" method="morph" target=#{id.to_json}><template>' +
            window.__snapshots[#{snapshot.to_json}] + "</template></turbo-stream>"
        )
      JS
    end

    it "requests nothing on page load, then GETs the fragment once when the event fires" do
      visit "/cached_panel"
      expect(page).to have_css("[data-testid='cached-panel-skeleton']")
      expect(fragment_fetches).to be_empty
      expect(page).to have_reactive_requests(0)

      fire_panel_opened
      expect(page).to have_css("[data-testid='cached-panel-item']", text: "panel:mine")

      expect(network_fetches.size).to eq(1)
      expect(page).to have_reactive_requests(1, kind: :defer)
      expect(page).to have_reactive_requests(0, kind: :action)

      fire_panel_opened
      expect(page).to have_reactive_requests(1)
    end

    it "re-materializes a morph-back from the browser cache: no network request" do
      visit "/cached_panel"
      snapshot("cached-panel", as: "shell")
      fire_panel_opened
      expect(page).to have_css("[data-testid='cached-panel-item']")
      page.execute_script(
        %(document.querySelector("[data-testid='cached-panel-item']").setAttribute("data-stale", "yes"))
      )

      morph_to("cached-panel", snapshot: "shell")

      expect(page).to have_css("[data-testid='cached-panel-item']:not([data-stale])", text: "panel:mine")
      expect(fragment_fetches.size).to eq(2)
      expect(network_fetches.size).to eq(1)
    end

    # The honest limit of the default mode: Rails' cookie session store issues a
    # NEW session cookie on every page response, and `Vary: Cookie` then (rightly)
    # refuses the stored copy. Declaring reactive_cache_viewer is what makes a
    # fragment reusable across page views there.
    it "asks the server again on the next page view when the session cookie changed (Vary: Cookie)" do
      visit "/cached_panel"
      fire_panel_opened
      expect(page).to have_css("[data-testid='cached-panel-item']")

      visit "/cached_panel"
      fire_panel_opened
      expect(page).to have_css("[data-testid='cached-panel-item']")

      expect(network_fetches.size).to eq(1)
    end
  end
end
