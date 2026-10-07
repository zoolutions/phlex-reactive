# frozen_string_literal: true

require "rails_helper"

# Issue #337: the client's default JSON body keeps each field's bracketed name
# as ONE literal key ("todo[title]"). The endpoint used to look for the scope
# key ("todo") before those names were expanded, found none, peeled nothing,
# and the FLAT schema then saw { "todo" => { … } } — one level too deep — so
# every scoped field was dropped. Only the multipart body (Rails expands the
# brackets itself) worked, and JSON is the default.
RSpec.describe "reactive_scope over the JSON wire shape (issue #337)", type: :request do
  let!(:todo) { Todo.create!(title: "old") }
  let(:payload) { { "gid" => todo.to_gid.to_s } }

  # post_reactive_multipart posts a form-encoded body unless a file part is
  # present; this undeclared file (dropped by the schema) makes rack-test send
  # real multipart/form-data, the encoding the client uses for a :file param.
  def multipart(params)
    params.merge("upload" => Rack::Test::UploadedFile.new(StringIO.new("x"), "text/plain", original_filename: "x.txt"))
  end

  def received(response)
    JSON.parse(CGI.unescapeHTML(response.body[%r{data-testid="received">(.*?)</pre>}m, 1]))
  end

  it "matches a flat schema against a JSON body carrying \"todo[title]\"" do
    post_reactive_action(ScopedEditorComponent, :save, payload:, params: { "todo[title]" => "Buy milk" })

    expect(response).to have_http_status(:ok)
    expect(todo.reload.title).to eq("Buy milk")
  end

  it "still matches a nested-hash JSON body" do
    post_reactive_action(ScopedEditorComponent, :save, payload:, params: { todo: { title: "Buy milk" } })

    expect(todo.reload.title).to eq("Buy milk")
  end

  it "still matches a multipart body" do
    post_reactive_multipart(ScopedEditorComponent, :save, payload:, params: multipart({ todo: { title: "Buy milk" } }))

    expect(request.media_type).to eq("multipart/form-data")
    expect(response).to have_http_status(:ok)
    expect(todo.reload.title).to eq("Buy milk")
  end

  it "expands a deeper bracketed group (todo[tags][]) into the flat array param" do
    post_reactive_action(ScopedEditorComponent, :echo, payload:,
      params: { "todo[title]" => "t", "todo[tags][]" => %w[ruby rails] })

    expect(received(response)).to eq("title" => "t", "tags" => %w[ruby rails])
  end

  it "keeps a bare sibling param (a trigger param) beside the scoped fields over JSON" do
    # on(:echo, note: "x") posts `note` bare, next to the scoped fields.
    post_reactive_action(ScopedEditorComponent, :echo, payload:,
      params: { "todo[title]" => "t", "note" => "from the trigger" })

    expect(received(response)).to eq("title" => "t", "note" => "from the trigger")
  end

  it "keeps a bare sibling param beside the scoped fields over multipart" do
    post_reactive_multipart(ScopedEditorComponent, :echo, payload:,
      params: multipart({ "todo" => { "title" => "t" }, "note" => "from the trigger" }))

    expect(received(response)).to eq("title" => "t", "note" => "from the trigger")
  end

  it "lets an explicit bare param win over a scoped field of the same name" do
    # The client's rule: an explicit on(:act, title: …) param wins over a
    # collected field. Under a scope the two arrive as different wire keys
    # (title vs todo[title]), so the endpoint has to keep that precedence.
    post_reactive_action(ScopedEditorComponent, :echo, payload:,
      params: { "title" => "explicit", "todo[title]" => "field" })

    expect(received(response)).to eq("title" => "explicit")
  end

  it "passes bare params through when the scope key is absent" do
    post_reactive_action(ScopedEditorComponent, :echo, payload:, params: { "note" => "only" })

    expect(received(response)).to eq("note" => "only")
  end

  it "does not peel a scope key that maps to a scalar" do
    post_reactive_action(ScopedEditorComponent, :echo, payload:, params: { "todo" => "scalar", "note" => "n" })

    expect(response).to have_http_status(:ok)
    expect(received(response)).to eq("note" => "n")
  end

  it "stays default-deny: undeclared fields, scoped or bare, are dropped" do
    post_reactive_action(ScopedEditorComponent, :echo, payload:,
      params: { "todo[title]" => "ok", "todo[admin]" => "true", "evil" => "x" })

    expect(received(response)).to eq("title" => "ok")
  end

  it "keeps a posted scoped group when the same group is also announced empty (multipart)" do
    post_reactive_multipart(ScopedEditorComponent, :echo, payload:,
      params: multipart({ "todo" => { "tags" => %w[ruby] } }), empty_groups: ["todo[tags]"])

    expect(received(response)).to eq("tags" => %w[ruby])
  end

  describe "verbose_errors" do
    around do
      Phlex::Reactive.verbose_errors = true
      it.run
    ensure
      Phlex::Reactive.remove_instance_variable(:@verbose_errors)
    end

    before { allow(Rails.logger).to receive(:warn).and_call_original }

    it "no longer logs the scoped field as dropped, while still logging a real drop" do
      post_reactive_action(ScopedEditorComponent, :echo, payload:,
        params: { "todo[title]" => "ok", "todo[evil]" => "x" })

      expect(Rails.logger).to have_received(:warn).with(a_string_including("dropped params:", "evil (undeclared)"))
      expect(Rails.logger).not_to have_received(:warn).with(a_string_including("title"))
    end
  end
end
