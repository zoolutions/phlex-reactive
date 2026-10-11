# frozen_string_literal: true

require 'system_helper'

# The sortable-lists guide's live demo (issue #350) in a real browser: a mouse
# drag reorders, a template dragged in is inserted by the list's action, and
# the keyboard model moves a row.
RSpec.describe 'Sortable lists', type: :system do
  def tasks
    page.evaluate_script(<<~JS)
      [...document.querySelectorAll("[data-testid='sortable-tasks-list'] > li")].map((el) => el.textContent.replace("⠿", "").trim())
    JS
  end

  def center(selector)
    page.evaluate_script(<<~JS)
      (() => { const r = document.querySelector(#{selector.to_json}).getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2] })()
    JS
  end

  # A real mouse drag from `source` to `nudge` px below/above `target`'s middle.
  def drag(source, target, nudge: 0)
    from = center(source)
    to_x, to_y = center(target)
    page.driver.with_playwright_page { |pw| mouse_drag(pw.mouse, from, [to_x, to_y + nudge]) }
  end

  # Press at `from`, pass the 4 px threshold, glide to `to`, release.
  def mouse_drag(mouse, from, to)
    mouse.move(*from)
    mouse.down
    mouse.move(from[0] + 8, from[1] + 8, steps: 2)
    mouse.move(*to, steps: 10)
    mouse.up
  end

  before do
    visit '/docs/sortable-lists'
    page.execute_script("document.querySelector(\"[data-testid='sortable-tasks']\").scrollIntoView({ block: 'center' })")
  end

  it 'reorders a task by dragging its handle' do
    drag('#task-write-the-failing-spec [data-drag-handle]', '#task-refactor', nudge: 8)
    expect(page).to have_css("[data-testid='sortable-tasks-list'] > li:nth-child(3)", text: 'Write the failing spec')
    expect(tasks).to eq(['Make it pass', 'Refactor', 'Write the failing spec', 'Open the pull request'])
  end

  it 'inserts a copy of a template dragged into the list' do
    drag("[data-testid='template-bug']", '#task-make-it-pass', nudge: -8)
    expect(page).to have_css("[data-testid='sortable-tasks']", text: 'Tasks (5)')
    expect(tasks).to include('Triage a bug report')
    expect(page).to have_css("[data-testid='template-bug']")
  end

  it 'moves a task with the keyboard' do
    row = find_by_id('task-refactor')
    row.send_keys(:space, :up, :up, :space)
    expect(page).to have_css("[data-testid='sortable-tasks-list'] > li:first-child", text: 'Refactor')
  end
end
