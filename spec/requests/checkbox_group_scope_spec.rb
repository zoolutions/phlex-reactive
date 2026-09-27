# frozen_string_literal: true

require "rails_helper"

# Issue #258: a component with `reactive_scope` posts its group under the scope
# (todo[tags][]), so the announcement carries the scoped name. It has to land
# where the FLAT schema looks for it — which is after the endpoint peels one
# scope level, not before.
RSpec.describe "Announced group under reactive_scope (issue #258)", type: :request do
  let!(:todo) { Todo.create!(title: "t") }
  let(:payload) { { "gid" => todo.to_gid.to_s } }

  def received_tags(response)
    JSON.parse(CGI.unescapeHTML(response.body[%r{data-testid="received-tags">(.*?)</pre>}m, 1]))
  end

  it "fills a scoped group announced by its scoped name" do
    post_reactive_multipart(ScopedEditorComponent, "save_tags", payload:,
      params: { "todo" => { "title" => "t" } }, empty_groups: ["todo[tags]"])

    expect(response).to have_http_status(:ok)
    expect(received_tags(response)).to eq([])
  end

  it "fills it even when the scope key is absent from params entirely" do
    # The only reason the body is multipart is an unscoped file input, so the
    # scope key can be missing altogether. unwrap_scope then peels nothing, and
    # the announcement has to land on the params root it actually left behind.
    post_reactive_multipart(ScopedEditorComponent, "save_tags", payload:,
      params: {}, empty_groups: ["todo[tags]"])

    expect(response).to have_http_status(:ok)
    expect(received_tags(response)).to eq([])
  end

  it "accepts the bare declared name too" do
    # There is no helper that can emit a scoped group name — scoped_field_name
    # would build todo[tags[]], which the client does not read as a group — so a
    # scoped group is always hand-written, and the obvious hand-writing is the
    # unscoped `tags[]` from the README.
    post_reactive_multipart(ScopedEditorComponent, "save_tags", payload:,
      params: { "todo" => { "title" => "t" } }, empty_groups: ["tags"])

    expect(response).to have_http_status(:ok)
    expect(received_tags(response)).to eq([])
  end
end
