# frozen_string_literal: true

require 'rails_helper'

# The editable-text demo card (issue #351): rename persists the stripped title
# (inner spacing kept); a blank title is not saved and says so.
RSpec.describe 'EditableCard actions', type: :request do
  let!(:todo) { Todo.create!(title: 'draft') }
  let(:payload) { { 'gid' => todo.to_gid.to_s, 's' => { 'note' => 'n' } } }

  it 'strips boundary whitespace but keeps inner spacing' do
    post_action(EditableCardComponent, payload:, act: 'rename', params: { title: '  A  B  ' })

    expect(todo.reload.title).to eq('A  B')
  end

  it 'does not save a blank title and tells the user why' do
    post_action(EditableCardComponent, payload:, act: 'rename', params: { title: '   ' })

    expect(todo.reload.title).to eq('draft')
    expect(response.body).to include('data-testid="editable-blank"')
  end
end
