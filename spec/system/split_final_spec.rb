# frozen_string_literal: true

require "system_helper"

# Issue #275, the last phase: the FEATURE MODULES the split client imports only
# when something needs them — bindings (show, filter, tags, nested rows, the
# conditional confirm), compute, hints (optimistic/busy) and devtools. These
# examples pin what each must not lose while its module is on its way:
#
#   hints     the first click of a cold page — live, replayed from before the
#             controller connected, or waking a dormant root — goes out ONCE,
#             after the module, with its hint applied; a failure after a late
#             module still rolls the optimistic hint back;
#   compute   computed fields show the server's values for a measured window,
#             then the seed runs; an edit in the window is recomputed, not
#             clobbered;
#   bindings  a choice made in a show-bound form before the module arrived is
#             kept and reflected once it has.
#
# ?slow=<ms>&slow_feature=<name> serves that one module late.
RSpec.describe "The split client: the bindings, compute, hints and devtools feature modules (issue #275)",
  :split_client, type: :system do
  # Requests for the feature module (served normally, or late by the slow
  # route). Not "/#{name}.js": the compute SEAM is /vendor/compute.js.
  def fetches(name)
    page.evaluate_script(<<~JS)
      performance.getEntriesByType("resource")
        .filter((e) => e.name.includes("/features/#{name}.js") || e.name.includes("/slow_feature/#{name}.js")).length
    JS
  end

  def action_posts = page.evaluate_script("window.__actionPosts")

  describe "hints: the first click of a cold page (the D1 cases)" do
    # The hint shows once the module has arrived and before the reply lands
    # (the action sleeps 0.3 s; the reply's re-render then replaces the button).
    def expect_one_bump
      expect(page).to have_css("[data-testid='bump'].pressed") # the optimistic hint, applied after the import
      expect(page).to have_css("[data-testid='bump']", text: "Bumping…") # the busy hint, likewise
      expect(page).to have_css("[data-testid='clicks']", text: "1")
      expect(page).to have_no_css("#hinted-panel[aria-busy]")
      wait_for_reactive
      expect(action_posts).to eq(1)
      expect(fetches("hints")).to eq(1)
    end

    it "a live first click (controller registered eagerly): one request, after the module, with the hint" do
      visit "/hinted?load=eager&slow=800&slow_feature=hints"
      expect(page).to have_css("#hinted-panel[data-reactive-connected]")

      find("[data-testid='bump']").click

      # The busy markers cover the wait: aria-busy is on before the module is.
      expect(page).to have_css("#hinted-panel[aria-busy='true']")
      expect_one_bump
    end

    it "a click replayed from before the controller connected: one request, after the module" do
      visit "/hinted?slow=800&slow_feature=hints"
      expect(page).to have_css("#hinted-panel")
      expect(page.evaluate_script("window.__earlyReady === true")).to be(true)

      find("[data-testid='bump']").click # captured by phlex/reactive/early
      page.execute_script("window.__loadReactive()")

      expect_one_bump
    end

    it "a click that wakes a dormant root: one request, after the module" do
      visit "/hinted?dormant=1&load=auto&slow=800&slow_feature=hints"
      expect(page).to have_css("#hinted-panel[data-reactive-dormant='reactive']")
      expect(page.evaluate_script("window.__earlyReady === true")).to be(true)

      find("[data-testid='bump']").click # wakes the root; the controller loads; the click is replayed

      expect_one_bump
    end

    it "a failure after a late-arriving module still rolls the optimistic hint back" do
      visit "/hinted?load=eager&slow=800&slow_feature=hints"
      expect(page).to have_css("#hinted-panel[data-reactive-connected]")

      find("[data-testid='boom']").click

      expect(page).to have_css("[data-testid='boom'].pressed") # applied once the module arrived
      expect(page).to have_no_css("[data-testid='boom'].pressed") # the 403 reverted it
      expect(page).to have_css("#hinted-panel[data-reactive-error='http']")
      wait_for_reactive
      expect(action_posts).to eq(1)
    end

    it "the busy hint applied late is undone when the request settles" do
      visit "/hinted?load=eager&slow=800&slow_feature=hints"
      expect(page).to have_css("#hinted-panel[data-reactive-connected]")

      find("[data-testid='boom']").click # a reply that does NOT re-render the button

      expect(page).to have_css("[data-testid='boom'].pressed", text: "Booming…") # after the module
      expect(page).to have_css("#hinted-panel[data-reactive-error='http']")
      expect(page).to have_no_css("[data-testid='boom'].pressed")
      expect(page).to have_css("[data-testid='boom']", exact_text: "Boom") # restored on settle
      expect(page).to have_no_css("#hinted-panel[aria-busy]")
    end
  end

  describe "compute: the window before the seed" do
    it "shows the server's values until the module arrives, then seeds" do
      visit "/compute_seed?slow=800&slow_feature=compute"
      expect(page).to have_css("#compute-seed[data-reactive-connected]")
      expect(page).to have_field("total", with: "") # the window: as the server rendered it

      expect(page).to have_field("total", with: "6") # the seed, once the module ran
      expect(page).to have_css("#seed-total-label", text: "6")
      expect(fetches("compute")).to eq(1)
    end

    it "an edit in the window is recomputed from the user's value, not clobbered" do
      visit "/compute_seed?slow=800&slow_feature=compute"
      expect(page).to have_css("#compute-seed[data-reactive-connected]")
      expect(page).to have_field("total", with: "") # the window: the server rendered it blank

      find("[data-testid='a']").fill_in(with: "10")

      expect(page).to have_field("total", with: "14") # 10 + 4, once the module ran
      expect(page).to have_field("a", with: "10")
      expect(fetches("compute")).to eq(1)
    end

    it "measures the window on the split client with the module served normally" do
      visit "/compute_seed"
      expect(page).to have_field("total", with: "6")
      # Measured from the page itself: the time between the root's connect and
      # the seed's write, with the module fetched from the local server.
      ms = page.evaluate_script(<<~JS)
        (() => {
          const connect = performance.getEntriesByType("resource").find((e) => e.name.includes("/vendor/core.js"))
          const compute = performance.getEntriesByType("resource").find((e) => e.name.includes("/features/compute.js"))
          return connect && compute ? Math.round(compute.responseEnd - connect.responseEnd) : null
        })()
      JS
      RSpec.configuration.reporter.message(
        "compute window on the split client (core loaded → compute module loaded, localhost): #{ms} ms"
      )
      expect(ms).to be_a(Integer)
      expect(ms).to be >= 0
    end
  end

  describe "bindings: the window before the module" do
    it "a choice made in a show-bound form before the module arrived is kept and reflected once it has" do
      visit "/conditional_fieldset?slow=800&slow_feature=bindings"
      expect(page).to have_css("#conditional-fieldset[data-reactive-connected]")
      expect(page).to have_css("[data-testid='mode-details']", visible: :hidden)

      select "Express", from: "mode" # in the window: nothing reacts yet

      expect(page).to have_css("[data-testid='mode-details']", visible: :visible)
      expect(page).to have_css("#cf-mode-badge", visible: :visible)
      expect(page).to have_select("mode", selected: "Express")
      expect(fetches("bindings")).to eq(1)
    end

    it "is not fetched by a page with no bindings" do
      visit "/counter"
      find("[data-testid='inc']").click
      expect(page).to have_css("[data-testid='count']", text: "1")

      expect(fetches("bindings")).to eq(0)
      expect(fetches("compute")).to eq(0)
      expect(fetches("hints")).to eq(0)
      expect(fetches("devtools")).to eq(0)
    end
  end
end
