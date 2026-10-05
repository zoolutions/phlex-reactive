# frozen_string_literal: true

require "system_helper"

# Issue #275, phase 4: three more FEATURE MODULES the split client imports
# only when something needs them —
#
#   effects  stream effects and self-dismissing flashes (document-level);
#   form     dirty tracking, the unsaved guard, the paste-trigger gate;
#   dev      the latency simulator.
#
# These examples pin when each is fetched, and that the thing which made the
# client fetch it is not lost on the way: the stream that introduces a page's
# first effect or flash still gets it (its render waits for the module, and so
# does any stream behind it), an edit made before the form module arrived is
# counted, a request made while a delay is stored is delayed.
#
# ?slow=<ms>&slow_feature=<name> serves that one module late.
RSpec.describe "The split client: the effects, form and dev feature modules (issue #275)", :split_client, type: :system do
  def fetches(name)
    page.evaluate_script(<<~JS)
      performance.getEntriesByType("resource").filter((e) => e.name.includes("/#{name}.js")).length
    JS
  end

  # What a broadcast delivers: a turbo-stream message, rendered by Turbo.
  def broadcast(message)
    page.execute_script("Turbo.renderStreamMessage(#{message.to_json})")
  end

  it "fetches none of them on a page that uses none" do
    visit "/counter"
    find("[data-testid='inc']").click
    expect(page).to have_css("[data-testid='count']", text: "1")

    expect(fetches("effects")).to eq(0)
    expect(fetches("form")).to eq(0)
    expect(fetches("dev")).to eq(0)
  end

  describe "effects" do
    it "is fetched at connect by a page whose roots declare an effect" do
      visit "/effects"
      expect(page).to have_css("#fx-row-1[data-reactive-connected]")

      expect(fetches("effects")).to eq(1)
    end

    it "a REPLY that brings the page's first dismissing flash loads it; the flash shows and dismisses on time" do
      visit "/failure_surface?slow=600&slow_feature=effects"
      expect(page).to have_css("#failure-surface[data-reactive-connected]")
      expect(fetches("effects")).to eq(0)
      # When the flash entered the page and when it left it.
      page.execute_script(<<~JS)
        new MutationObserver(() => {
          const flash = document.querySelector("#flash [data-reactive-dismiss-after]")
          if (flash && !window.__flashIn) window.__flashIn = performance.now()
          if (!flash && window.__flashIn && !window.__flashOut) window.__flashOut = performance.now()
        }).observe(document.getElementById("flash"), { childList: true, subtree: true })
      JS

      find("[data-testid='flash-now']").click

      # The reply's streams waited for the module, then rendered — both of them.
      expect(page).to have_css("#flash [data-reactive-dismiss-scheduled]", text: "gone soon")
      expect(page).to have_css("[data-testid='count']", text: "0")
      expect(page).to have_no_css("#flash [data-reactive-dismiss-after]")
      expect(fetches("effects")).to eq(1)
      # dismiss_after: 800 counts from the RENDER, not from the click.
      shown_for = page.evaluate_script("window.__flashOut - window.__flashIn")
      expect(shown_for).to be_between(700, 1500)
    end

    it "a BROADCAST with the page's first effect animates THAT stream, and the streams behind it keep their order" do
      visit "/counter?slow=700&slow_feature=effects"
      expect(page).to have_css("#counter[data-reactive-connected]")
      expect(fetches("effects")).to eq(0)
      page.execute_script(<<~JS)
        const style = document.createElement("style")
        style.textContent = "@keyframes fx-out { to { opacity: 0 } } .reactive-fx--fade-exit { animation: fx-out 900ms }"
        document.head.appendChild(style)
      JS

      # One message, three streams: append a note (nothing to animate), give it
      # new text (must come AFTER the append — its target does not exist
      # before), remove a row with a per-call effect.
      broadcast(<<~HTML)
        <turbo-stream action="append" targets="body"><template><p id="doomed">doomed</p></template></turbo-stream>
        <turbo-stream action="remove" target="doomed" data-reactive-effect="fade"></turbo-stream>
        <turbo-stream action="append" targets="body"><template><p id="note">first</p></template></turbo-stream>
        <turbo-stream action="update" target="note"><template>second</template></turbo-stream>
      HTML

      # The removal is animated, not instant: the module arrived first.
      expect(page).to have_css("#doomed.reactive-fx--fade-exit")
      expect(page).to have_no_css("#doomed")
      expect(page).to have_css("#note", text: "second")
      expect(fetches("effects")).to eq(1)
    end

    it "does not hold a stream for long: with the module stuck, streams render plain after about a second" do
      visit "/counter?slow=5000&slow_feature=effects"
      expect(page).to have_css("#counter[data-reactive-connected]")

      broadcast(<<~HTML)
        <turbo-stream action="append" targets="body"><template><p id="late" data-reactive-dismiss-after="60000">late</p></template></turbo-stream>
      HTML

      # Well inside the 5 s the module takes.
      expect(page).to have_css("#late", wait: 3)
      expect(page).to have_no_css("#late[data-reactive-dismiss-scheduled]")
      # When the module does arrive it picks the flash up.
      expect(page).to have_css("#late[data-reactive-dismiss-scheduled]", wait: 8)
    end
  end

  describe "form" do
    it "is fetched by a dirty-tracked form, and an edit made before it arrived is counted" do
      todo = Todo.create!(title: "original")
      visit "/dirty_form/#{todo.id}?slow=800&slow_feature=form"
      expect(page).to have_css("[id^='dirtyform'][data-reactive-connected]")

      find("[data-testid='title']").set("edited")

      expect(page).to have_css("[id^='dirtyform'][data-reactive-dirty='1']")
      expect(page).to have_css("[data-testid='badge']", visible: :visible, text: "Unsaved")
      expect(fetches("form")).to eq(1)
    end

    it "reveals a paste trigger once it has arrived" do
      visit "/verification?slow=500&slow_feature=form"

      expect(page).to have_css("[data-reactive-clipboard]", visible: :visible)
      expect(fetches("form")).to eq(1)
    end
  end

  describe "dev" do
    it "is fetched by a page with the development meta, and attaches the console handle" do
      visit "/latency"
      expect(page).to have_css("#latency[data-reactive-connected]")

      expect(page).to have_css("#latency") # (settle)
      Timeout.timeout(5) { sleep 0.05 until page.evaluate_script("typeof window.PhlexReactive") == "object" }
      expect(fetches("dev")).to eq(1)
    end

    it "delays the very first request when a delay is stored, on a page without the meta" do
      visit "/counter"
      page.execute_script("sessionStorage.setItem('phlex-reactive:latency', '1200')")
      visit "/counter?slow=300&slow_feature=dev"
      expect(page).to have_css("#counter[data-reactive-connected]")

      find("[data-testid='inc']").click

      expect(page).to have_css("#counter[aria-busy='true']")
      expect(page).to have_css("[data-testid='count']", text: "1", wait: 8)
      expect(page.evaluate_script("typeof window.PhlexReactive")).to eq("undefined")
      expect(fetches("dev")).to eq(1)
    ensure
      page.execute_script("sessionStorage.clear()")
    end
  end
end
