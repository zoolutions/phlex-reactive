# frozen_string_literal: true

require 'system_helper'

# The Project board flagship (issue #216) in a real browser: cards dragged
# across lanes (sortable lists, issue #350) — by mouse and by keyboard — with
# live count badges, per-lane composers,
# Enter-to-save inline rename (morph — the input survives), confirm-gated
# archive, and the effect-style picker riding signed state. Cross-tab delivery
# is asserted at the request level (broadcast specs) per the docs convention —
# the demo site's cable adapter is in-process.
RSpec.describe 'Project board', type: :system do
  # System specs hit a real server on a separate DB connection — seed
  # explicitly per example, never rely on transactional fixtures.
  before { Card.delete_all }

  def demo = first("[data-testid='live-example-demo']")

  def center(selector)
    page.evaluate_script(<<~JS)
      (() => { const r = document.querySelector("#{selector}").getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2] })()
    JS
  end

  # A real mouse drag from the card's handle to the middle of a lane's list.
  def drag_card_to(lane)
    page.execute_script("document.querySelector(\"[data-testid='lane-#{lane}']\").scrollIntoView({ block: 'center' })")
    from = center("[data-testid='drag-handle']")
    to = center("#lane-#{lane}-cards")
    page.driver.with_playwright_page { |pw| mouse_drag(pw.mouse, from, to) }
  end

  # Press at `from`, pass the 4 px threshold, glide to `to`, release.
  def mouse_drag(mouse, from, to)
    mouse.move(*from)
    mouse.down
    mouse.move(from[0] + 8, from[1] + 8, steps: 2)
    mouse.move(*to, steps: 10)
    mouse.up
  end

  it 'drags a card across lanes with live counts, twice, without a reload' do
    Card.create!(title: 'Ship the board', lane: 'todo', position: 1)
    visit '/docs/example-project-board'
    expect(page).to have_css("[data-testid='count-todo']", text: '1')

    page.execute_script("window.__noReload = 'alive'")

    within demo do
      drag_card_to('doing')
      # The card's title lives in an input VALUE — assert via have_field
      # scoped to the destination lane (text: can't see input values).
      within "[data-testid='lane-doing']" do
        expect(page).to have_field('title', with: 'Ship the board')
      end
      expect(page).to have_css("[data-testid='count-todo']", text: '0')
      expect(page).to have_css("[data-testid='count-doing']", text: '1')

      # A second move proves the morphed board carries FRESH tokens.
      drag_card_to('done')
      within "[data-testid='lane-done']" do
        expect(page).to have_field('title', with: 'Ship the board')
      end
      expect(page).to have_css("[data-testid='count-done']", text: '1')
      expect(page).to have_css("[data-testid='count-doing']", text: '0')
    end

    expect(Card.sole.lane).to eq('done')
    expect(page.evaluate_script('window.__noReload')).to eq('alive')
  end

  it 'moves a card with the keyboard: Space picks it up, → hops a lane, Space drops it' do
    Card.create!(title: 'Keyboard card', lane: 'todo', position: 1)
    visit '/docs/example-project-board'

    within demo do
      card = find("[data-testid='board-card']")
      card.send_keys(:space)
      expect(page).to have_css("[data-testid='board-card'][data-reactive-sortable-dragging]")
      card.send_keys(:right)
      card.send_keys(:space)
      within "[data-testid='lane-doing']" do
        expect(page).to have_field('title', with: 'Keyboard card')
      end
      expect(page).to have_css("[data-testid='count-doing']", text: '1')
    end
    expect(Card.sole.lane).to eq('doing')
  end

  it 'adds a card from a lane composer and flashes on a blank title' do
    visit '/docs/example-project-board'

    within demo do
      find("[data-testid='new-card-doing']").fill_in(with: 'Write the docs page')
      find("[data-testid='add-doing']").click
      within "[data-testid='lane-doing']" do
        expect(page).to have_field('title', with: 'Write the docs page')
      end
      expect(page).to have_css("[data-testid='count-doing']", text: '1')
      # The board replace cleared the composer (the have_css above is the
      # barrier — the fresh render has landed).
      expect(find("[data-testid='new-card-doing']").value).to eq('')

      find("[data-testid='add-todo']").click # blank title
    end
    expect(page).to have_css('#flash', text: 'A card needs a title')
  end

  it 'renames inline on Enter — the morph keeps the row in place' do
    card = Card.create!(title: 'Old name', lane: 'todo', position: 1)
    visit '/docs/example-project-board'

    within demo do
      input = find("[data-testid='card-title']")
      input.fill_in(with: 'New name')
      input.send_keys(:enter)
      expect(page).to have_field('title', with: 'New name')
    end
    expect(Card.find(card.id).title).to eq('New name')
  end

  it 'archives through the confirm gate and repaints the count' do
    Card.create!(title: 'Done with this', lane: 'done', position: 1)
    visit '/docs/example-project-board'
    expect(page).to have_css("[data-testid='count-done']", text: '1')

    within demo do
      accept_confirm { find("[data-testid='archive-card']").click }
      expect(page).to have_no_css("[data-testid='board-card']")
      expect(page).to have_css("[data-testid='count-done']", text: '0')
    end
    expect(page).to have_css('#flash', text: 'Card archived')
  end

  it 'keeps the picked effect style across round trips (signed state)' do
    Card.create!(title: 'Style me', lane: 'todo', position: 1)
    visit '/docs/example-project-board'

    within demo do
      find("[data-testid='style-scale']").click
      expect(page).to have_css("[data-testid='style-scale'].btn-active")

      # The pick survives the next action's round trip — it rides the signed
      # state, not the DOM.
      find("[data-testid='new-card-doing']").fill_in(with: 'Another')
      find("[data-testid='add-doing']").click
      expect(page).to have_css("[data-testid='count-doing']", text: '1')
      expect(page).to have_css("[data-testid='style-scale'].btn-active")
    end
  end
end
