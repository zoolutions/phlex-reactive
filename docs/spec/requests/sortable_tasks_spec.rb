# frozen_string_literal: true

require 'rails_helper'

# The sortable-lists demo (issue #350): the task order is signed state; a drop
# sends :move (a reorder) or :insert (a template dragged in), and the reply
# morphs the list in the server's order.
RSpec.describe 'Sortable tasks demo', type: :request do
  def payload(tasks) = { 's' => { 'tasks' => tasks } }

  let(:tasks) { %w[A B C] }

  it 'renders the list as a sortable taking drag-ins from the templates source' do
    get '/docs/sortable-lists'

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('data-reactive-sortable="move"', 'data-reactive-sortable-group="tasks"')
    expect(response.body).to include('data-reactive-sortable-source="templates"')
  end

  it 'moves a task to the dropped position and morphs' do
    post_action(SortableTasksComponent, payload: payload(tasks), act: 'move', params: { item: 'A', position: 2 })

    expect(response.body).to include('method="morph"')
    expect(response.body.index('task-a')).to be > response.body.index('task-c')
  end

  it 'ignores a key that is not in the list' do
    post_action(SortableTasksComponent, payload: payload(tasks), act: 'move', params: { item: 'Z', position: 0 })

    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include('task-z')
  end

  it 'inserts a copy of a template at the dropped position, numbering a second copy' do
    post_action(SortableTasksComponent, payload: payload(['Triage a bug report', 'B']), act: 'insert',
                                        params: { item: 'bug', position: 1 })

    body = response.body
    expect(body).to include('Triage a bug report (2)')
    expect(body.index('Triage a bug report (2)')).to be < body.index('task-b')
  end

  it 'refuses an unknown template and stops at the cap' do
    post_action(SortableTasksComponent, payload: payload(tasks), act: 'insert', params: { item: 'nope', position: 0 })
    expect(response.body).to include('Tasks (3)')

    full = Array.new(SortableTasksComponent::MAX_TASKS) { "T#{it}" }
    post_action(SortableTasksComponent, payload: payload(full), act: 'insert', params: { item: 'bug', position: 0 })
    expect(response.body).not_to include('Triage a bug report')
  end
end
