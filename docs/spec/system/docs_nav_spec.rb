# frozen_string_literal: true

require 'system_helper'

# The docs-kit docs-nav Stimulus controller: it persists sidebar collapse state
# to localStorage (client-only UI state — no server round-trip) so the sidebar
# stays how the reader left it across page navigations.
RSpec.describe 'Docs sidebar collapse persistence', type: :system do
  # Collapsing requires the sidebar visible; on a phone it's a hidden drawer, so
  # this interaction is asserted at desktop widths (responsive_spec covers the
  # drawer behavior on small screens).
  it 'remembers a collapsed sub-group across navigation', :desktop_only do
    visit '/docs/installation'

    # The "Examples" sub-group is a <details open> whose <summary> is the label.
    examples = find('summary', text: 'Examples')
    examples_details = examples.find(:xpath, './..') # the <details>

    expect(examples_details['open']).to be_truthy

    # The controller only persists toggles once connected, so wait for it.
    sidebar = find('[data-controller~="docs-nav"]')
    connected = "Stimulus.getControllerForElementAndIdentifier(arguments[0], 'docs-nav') !== null"
    page.document.synchronize { raise Capybara::ExpectationNotMet unless page.evaluate_script(connected, sidebar) }

    # Collapse it (native <details> toggle) and let the controller persist.
    examples.click
    expect(examples.find(:xpath, './..')['open']).to be_falsey

    # `toggle` fires async; navigating before it lands would drop the write.
    stored = "Object.keys(localStorage).some(k => k.endsWith(':nav:Examples') && localStorage[k] === 'closed')"
    page.document.synchronize { raise Capybara::ExpectationNotMet unless page.evaluate_script(stored) }

    # Navigate to another page; the sidebar re-renders server-side with the
    # section OPEN by default, but the controller restores the collapsed state.
    visit '/docs/architecture'

    # Waiting matcher: the restore runs when the controller connects, after load.
    expect(page).to have_css('details:not([open]) > summary', text: 'Examples')
  end

  it 'renders the sidebar under the docs-nav controller' do
    visit '/docs/installation'

    expect(page).to have_css('[data-controller~="docs-nav"]')
  end
end
