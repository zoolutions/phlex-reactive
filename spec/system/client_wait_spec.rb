# frozen_string_literal: true

require "system_helper"

# Issue #393: on_client(debounce:/throttle:) waits on the timers on() uses.
# Each trigger dispatches a CustomEvent; a page listener counts them onto the
# root's data attributes, so waiting matchers are the barrier.
RSpec.describe "on_client debounce: / throttle: (issue #393)", type: :system do
  before do
    visit "/client_wait"
    page.find("#client-wait[data-controller='reactive']")
    page.execute_script(<<~JS)
      const root = document.getElementById("client-wait")
      window.__counts = { debounced: 0, throttled: 0, every: 0 }
      for (const name of Object.keys(window.__counts)) {
        root.addEventListener(`cw:${name}`, () => {
          window.__counts[name] += 1
          root.dataset[name] = String(window.__counts[name])
        })
      }
    JS
  end

  def count(name) = page.evaluate_script("window.__counts.#{name}")

  it "runs a debounced op once, after the burst" do
    find("[data-testid='debounced']").send_keys("abcde")
    # Inside the 1 s window nothing has run yet.
    expect(count(:debounced)).to eq(0)

    expect(page).to have_css("#client-wait[data-debounced='1']")
    sleep 1.2 # past another window: no second run
    expect(count(:debounced)).to eq(1)
  end

  it "runs a throttled op on the first event and drops the rest of the window" do
    find("[data-testid='throttled']").send_keys("abcde")
    expect(page).to have_css("#client-wait[data-throttled='1']")
    expect(count(:throttled)).to eq(1)

    sleep 0.7 # the 600 ms window elapsed
    find("[data-testid='throttled']").send_keys("f")
    expect(page).to have_css("#client-wait[data-throttled='2']")
  end

  it "runs an unwaited op on every event, as before" do
    find("[data-testid='every']").send_keys("abc")

    expect(page).to have_css("#client-wait[data-every='3']")
  end
end
