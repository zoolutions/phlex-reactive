# frozen_string_literal: true

require "system_helper"

# Issue #97: reply.<verb>.js(...) pushes server-side client DOM ops over a
# reactive:js stream, emitted AFTER the render streams. The decisive end-to-end
# proof: after a save that morphs the component AND focuses a sibling field, the
# freshly morphed field is the active element — which only holds if the op stream
# ran on the POST-morph DOM (ops last, per the ordering contract). If the op ran
# before the morph, it would focus a node about to be replaced and focus would be
# lost.
#
# Runs under BOTH real servers (Puma default, Falcon via CAPYBARA_SERVER=falcon):
# a reactive round trip must work sync AND async.
RSpec.describe "reply.js focus lands on the morphed field (issue #97)", type: :system do
  it "focuses the next field after a morph save (server-pushed js op)" do
    account = Account.create!(name: "start")
    visit "/js_focus/#{account.id}"
    page.execute_script("window.__noReload = 'alive'")

    # Nothing is focused yet (the trigger is a button, not either field).
    fill_in "first", with: "typed value"
    click_button("Save")

    # The morphed render reads the saved value back — proving the round trip
    # landed and the morph applied (the field the op targets is now the fresh one).
    expect(page).to have_css("[data-testid='saved']", text: "typed value")
    expect(account.reload.name).to eq("typed value")

    # The decisive assertion: after the reply, focus is on the SECOND field —
    # moved there by the reactive:js op running on the post-morph DOM. A
    # waiting matcher: the focus op lands one frame after the op stream renders
    # (issue #446, past Turbo's stream focus restore).
    expect(page).to have_css("[data-testid='next']:focus")

    # No full-page reload happened.
    expect(page.evaluate_script("window.__noReload")).to eq("alive")
  end
end
