# frozen_string_literal: true

require "rails_helper"

# Issue #370: the endpoint reads X-Reactive-Held into reactive_held_fields for
# the duration of the action — names only, filtered to the action's declared
# params; malformed or absent reads as [] and never fails the request.
RSpec.describe "X-Reactive-Held (issue #370)", type: :request do
  let(:todo) { Todo.create!(title: "Final by A") }

  def save(title, held: nil)
    token = reactive_action_token(HeldNoteComponent, { "gid" => todo.to_gid.to_s })
    headers = { "Content-Type" => "application/json", "Accept" => "text/vnd.turbo-stream.html" }
    headers[Phlex::Reactive::HeldFields::HEADER] = held if held
    post Phlex::Reactive.action_path,
      params: { token:, act: "save", params: { title:, version: "1" } }.to_json,
      headers:
  end

  it "exposes the held names to the action, which refuses the overwrite" do
    save("Draft by B", held: '["title","is_admin"]')

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Someone changed the title to Final by A while you typed Draft by B")
    expect(response.body).to include(%(data-testid="held">title<))
    expect(todo.reload.title).to eq("Final by A")
  end

  # Issue #413: the refusal tells the client to keep the title held, so the
  # next keystroke posts it again instead of saving over A's change.
  it "names the refused field in X-Reactive-Refused" do
    save("Draft by B", held: '["title"]')

    expect(response.headers[Phlex::Reactive::HeldFields::REFUSED_HEADER]).to eq('["title"]')
  end

  it "is [] without the header: the save goes through" do
    save("Draft by B")

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(%(data-testid="held"></span>))
    expect(todo.reload.title).to eq("Draft by B")
    expect(response.headers).not_to have_key(Phlex::Reactive::HeldFields::REFUSED_HEADER)
  end

  it "sends * for a reply that refused every held field" do
    allow_any_instance_of(HeldNoteComponent).to receive(:save) { it.reply.morph.refused } # rubocop:disable RSpec/AnyInstance
    save("Draft by B", held: '["title"]')

    expect(response.headers[Phlex::Reactive::HeldFields::REFUSED_HEADER]).to eq("*")
  end

  it "reads a malformed header as nothing held" do
    save("Draft by B", held: "[not json")

    expect(response).to have_http_status(:ok)
    expect(todo.reload.title).to eq("Draft by B")
  end

  it "does not leak the list past the request" do
    save("Draft by B", held: '["title"]')

    expect(Phlex::Reactive::HeldFields.current).to eq([])
  end
end
