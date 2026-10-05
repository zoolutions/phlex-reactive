# frozen_string_literal: true

require "system_helper"

# Issue #275: the client's source is a core plus feature modules, and it ships
# as two entries. THIS is the default one — phlex/reactive/reactive_controller,
# one file with the core and every feature bundled in, what every app gets
# unless it opts into phlex/reactive/core.
#
# It must behave as the single-file client did before the split:
#
#   - nothing is fetched on demand — no core, no feature module, on any page;
#   - a draft is restored inside the controller's connect, so the "module is
#     still on its way" window of the split client does not exist here. Its
#     edge cases (an action fired before the restore, typing before it, leaving
#     before it) cannot happen: each is replayed below against a dummy page
#     that WOULD serve the persist module 1.5 s late if anything asked for it.
#
# (The rest of the browser suite runs on this entry too. These examples are the
# ones that are only true here; persist_feature_spec and defer_feature_spec
# hold the split client's counterparts.)
RSpec.describe "The default client: one file, nothing on demand (issue #275)", :default_client, type: :system do
  def storage_key = "phlex-reactive:persist:dummy-persist-action"
  # The delay the dummy would put on the persist MODULE — which nothing imports.
  def slow_ms = 1500

  def on_demand_fetches
    page.evaluate_script(<<~JS)
      performance.getEntriesByType("resource")
        .map((e) => e.name)
        .filter((name) => name.includes("/features/") || name.includes("/vendor/core.js") || name.includes("slow_feature"))
    JS
  end

  def seed_draft(fields)
    visit "/counter"
    page.execute_script(<<~JS)
      window.localStorage.clear()
      window.localStorage.setItem(#{storage_key.to_json}, JSON.stringify({ v: 1, savedAt: Date.now(), fields: #{fields.to_json} }))
    JS
  end

  def draft_fields
    raw = page.evaluate_script("window.localStorage.getItem(#{storage_key.to_json}) ?? '__none__'")
    return nil if raw == "__none__"

    (raw.is_a?(String) ? JSON.parse(raw) : raw).fetch("fields")
  end

  after { page.execute_script("window.localStorage.clear()") }

  it "fetches no feature module and no core on a page with drafts" do
    seed_draft("note" => "Ada")
    visit "/persist_action"

    expect(page).to have_field("note", with: "Ada")
    expect(on_demand_fetches).to eq([])
  end

  it "fetches no feature module on a page with a lazy root" do
    visit "/lazy_stats"

    expect(page).to have_css("[data-testid='stats-value']", text: "stats:week")
    expect(on_demand_fetches).to eq([])
  end

  it "fetches no feature module for effects, a dismissing flash, dirty tracking or the latency simulator" do
    visit "/effects"
    find("[data-testid='fx-ping']").click
    expect(page).to have_css("[data-testid='fx-demo'].reactive-fx--highlight-update")
    expect(on_demand_fetches).to eq([])

    visit "/failure_surface"
    find("[data-testid='flash-now']").click
    expect(page).to have_css("#flash [data-reactive-dismiss-scheduled]", text: "gone soon")
    expect(on_demand_fetches).to eq([])

    visit "/dirty_form/#{Todo.create!(title: "original").id}"
    find("[data-testid='title']").set("edited")
    expect(page).to have_css("[id^='dirtyform'][data-reactive-dirty='1']")
    expect(on_demand_fetches).to eq([])

    visit "/latency"
    expect(page).to have_css("#latency[data-reactive-connected]")
    expect(page.evaluate_script("typeof window.PhlexReactive")).to eq("object")
    expect(on_demand_fetches).to eq([])
  end

  it "a stream's effect is applied when its event fires — it never waits (the split client's hold does not exist)" do
    visit "/counter?slow=1500&slow_feature=effects"
    expect(page).to have_css("#counter[data-reactive-connected]")
    page.execute_script(<<~JS)
      const style = document.createElement("style")
      style.textContent = "@keyframes fx-out { to { opacity: 0 } } .reactive-fx--fade-exit { animation: fx-out 900ms }"
      document.head.appendChild(style)
      Turbo.renderStreamMessage(
        '<turbo-stream action="append" targets="body"><template><p id="doomed">doomed</p></template></turbo-stream>' +
        '<turbo-stream action="remove" target="doomed" data-reactive-effect="fade"></turbo-stream>'
      )
    JS

    # Animating well before the 1.5 s the module would take if it were fetched.
    expect(page).to have_css("#doomed.reactive-fx--fade-exit", wait: 1)
    expect(page).to have_no_css("#doomed")
    expect(on_demand_fetches).to eq([])
  end

  it "fetches no feature module for a deferred reply, and applies it" do
    visit "/defer"
    find("[data-testid='defer-bump']").click

    expect(page).to have_css("[data-testid='defer-count']", text: "1")
    expect(page).to have_css("[data-testid='totals-value']", text: "2")
    expect(page).to have_reactive_requests(1, kind: :defer)
    expect(on_demand_fetches).to eq([])
  end

  it "handles a lazy shell that a stream brings onto the page, with nothing fetched on demand" do
    visit "/counter"
    page.execute_script(<<~JS)
      fetch("/lazy_stats").then((response) => response.text()).then((html) => {
        const shell = new DOMParser().parseFromString(html, "text/html").getElementById("lazy-stats")
        Turbo.renderStreamMessage(
          `<turbo-stream action="append" targets="body"><template>${shell.outerHTML}</template></turbo-stream>`
        )
      })
    JS

    expect(page).to have_css("[data-testid='stats-value']", text: "stats:week")
    expect(on_demand_fetches).to eq([])
  end

  context "when the split client would still be waiting for its module" do
    it "has restored the draft by the time the root is connected" do
      seed_draft("note" => "Ada")
      visit "/persist_action?slow=#{slow_ms}"

      # One read, no waiting: connected and restored are the same moment.
      state = page.evaluate_script(<<~JS)
        new Promise((resolve) => {
          const look = () => {
            const root = document.querySelector("#persist-action[data-reactive-connected]")
            root ? resolve(root.querySelector("[name=note]").value) : requestAnimationFrame(look)
          }
          look()
        })
      JS
      expect(state).to eq("Ada")
      expect(on_demand_fetches).to eq([])
    end

    it "posts the restored value, once, for an action fired the moment the root connects" do
      seed_draft("note" => "Ada")
      visit "/persist_action?slow=#{slow_ms}"
      expect(page).to have_css("#persist-action[data-reactive-connected]")

      find("[data-testid='save']").click

      expect(page).to have_css("[data-testid='saved']", text: "got:Ada")
      expect(page).to have_reactive_requests(1, kind: :action)
    end

    it "drafts what is typed right after connect, without another keystroke" do
      seed_draft("note" => "Ada")
      visit "/persist_action?slow=#{slow_ms}"
      expect(page).to have_css("#persist-action[data-reactive-connected]")

      find("[data-testid='extra']").send_keys("typed early")

      expect(draft_fields).to eq("note" => "Ada", "extra" => "typed early")
    end

    it "keeps what was typed right after connect across leaving at once and coming back" do
      seed_draft("note" => "Ada")
      visit "/persist_action?slow=#{slow_ms}"
      expect(page).to have_css("#persist-action[data-reactive-connected]")
      find("[data-testid='extra']").send_keys("typed early")

      page.execute_script("Turbo.visit('/counter')")
      expect(page).to have_css("#counter")
      visit "/persist_action"

      expect(page).to have_field("note", with: "Ada")
      expect(page).to have_field("extra", with: "typed early")
    end

    it "posts the restored value even when the user leaves while the action is in flight" do
      seed_draft("note" => "Ada")
      visit "/persist_action?slow=#{slow_ms}"
      expect(page).to have_css("#persist-action[data-reactive-connected]")
      page.execute_script(<<~JS)
        window.__posted = []
        const original = window.fetch
        window.fetch = (input, init) => {
          if (String(input?.url ?? input).includes("/reactive/actions")) window.__posted.push(JSON.parse(init.body).params.note)
          return original(input, init)
        }
      JS

      # Click, then leave in the same task — the split client would still be
      # waiting for its module here and would post the server's blank.
      page.execute_script("document.querySelector(\"[data-testid='save']\").click(); Turbo.visit('/counter')")

      expect(page).to have_css("#counter")
      expect(page.evaluate_script("window.__posted")).to eq(["Ada"])
    end

    it "replays a click made before a lazily loaded controller existed, with the restored value, once" do
      seed_draft("note" => "Ada")
      visit "/persist_action?layout=lazy&slow=#{slow_ms}"
      expect(page.evaluate_script("window.__earlyReady === true")).to be(true)

      find("[data-testid='save']").click
      page.execute_script("window.__loadReactive()")

      expect(page).to have_css("[data-testid='saved']", text: "got:Ada")
      expect(page.evaluate_script("window.__actionPosts")).to eq(1)
      expect(on_demand_fetches).to eq([])
    end
  end
end
