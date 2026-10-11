# frozen_string_literal: true

require "rails_helper"
require_relative "../support/fake_pgbus_presence"

# Issue #358: a presence roster on a page. With a seat-capable transport the
# root carries its stream's signed src (the client subscribes from it); on
# Action Cable (the default suite) the render fails loudly instead of shipping
# a roster that can never fill.
RSpec.describe "the presence page (issue #358)", type: :request do
  it "raises a configuration error without per-connection presence" do
    skip "pgbus is loaded in this process" if defined?(Pgbus)
    expect { get "/presence" }.to raise_error(Phlex::Reactive::ConfigurationError, %r{zoolutions/pgbus#515})
  end

  it "renders the root with its presence src when the transport is capable" do
    FakePgbusPresence.install!(self)
    get "/presence"
    todo = Todo.first
    expect(response.body).to include(%(data-reactive-presence="/pgbus/streams/signed-#{todo.to_gid_param}:presence:viewers"))
    expect(response.body).to include('import "pgbus/stream_source_element"')
  end
end
