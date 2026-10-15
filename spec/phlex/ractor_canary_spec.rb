# frozen_string_literal: true

require "rails_helper"

# What the Ractor blocks below reach through constants: a Ractor block must be
# capture-free, so everything it touches is a constant or an input.
module RactorCanary
  SCHEMA = Ractor.make_shareable(
    { count: :integer, title: :string, done: :boolean, on: :date, tags: [:string], address: { street: :string } }
  )

  STREAM = (%(<turbo-stream action="replace" target="todo_7"><template>) +
            %(<li id="todo_7" data-reactive-token-value="t">x</li></template></turbo-stream>)).freeze

  # A record as ActionView::RecordIdentifier sees one, with a shareable name:
  # ActiveModel builds a class's model_name lazily, which a non-main Ractor
  # cannot write.
  class Todo
    NAME = Ractor.make_shareable(ActiveModel::Name.new(self, nil, "Todo"))

    attr_reader :id

    def initialize(id) = @id = id
    def to_key = [id]
    def model_name = NAME
    def to_model = self
    def persisted? = true
  end

  class TodoRow < Phlex::HTML
    include Phlex::Reactive::Streamable

    def initialize(todo:) = @todo = todo
    def id = dom_id(@todo)
    def view_template = li(id:) { "todo" }
  end

  RENDER_PENDING = "Phlex 2.4.1 reads its non-shareable Phlex::ATTRIBUTE_CACHE constant on every element " \
                   "with attributes; a per-Ractor cache is pending upstream (yippee-fun/phlex#1055)"

  SIGN_PENDING = "Phlex::Reactive.verifier is an ActiveSupport::MessageVerifier, which is not Ractor-shareable " \
                 "and which ActiveSupport cannot build or use outside the main Ractor either (Messages::Codec's " \
                 "class attributes and Messages::Metadata::ENVELOPE_SERIALIZERS are not shareable, ActiveSupport 8.1)"
end

# Tier 3 of conformance-kit, on Ruby 4.0 (skipped below it with the kit's
# reason): with the configuration finalized, phlex-reactive's pure operations
# run inside a non-main Ractor and agree with the main Ractor
# (zoolutions/phlex-reactive#364). What cannot run there yet is pending with
# its upstream reason, and fails the day it starts to pass.
RSpec.describe "phlex-reactive inside a non-main Ractor" do # rubocop:disable RSpec/DescribeClass
  # Other examples reset the param-type registry; finalize! is what boot does.
  before { Phlex::Reactive.finalize! }

  context "when coercing params through a compiled schema" do
    let(:subject_call) do
      -> { Phlex::Reactive::ParamSchema.compile(RactorCanary::SCHEMA).coerce(it) }
    end

    it_behaves_like "runs inside a non-main Ractor", inputs: [{
      "count" => "3", "title" => 4, "done" => "1", "on" => "2026-10-15",
      "tags" => ["a", 1], "address" => { "street" => 5 }, "junk" => "dropped"
    }]
    it_behaves_like "runs inside a non-main Ractor", inputs: [{ "count" => "x", "on" => "not a date", "tags" => "nope" }]
  end

  context "when wrapping a Turbo Stream" do
    let(:subject_call) do
      lambda do
        stream = Phlex::Reactive::Stream.wrap(RactorCanary::STREAM.html_safe, action: :replace, target: "todo_7",
          renders_root: true)
        [stream.to_s, stream.rx_action, stream.rx_target, stream.rx_carries_token?, stream.rx_refreshes_token_for?("todo_7")]
      end
    end

    it_behaves_like "runs inside a non-main Ractor"
  end

  context "when building a record's dom id" do
    let(:subject_call) do
      lambda do
        todo = RactorCanary::Todo.new(it)
        row = RactorCanary::TodoRow.new(todo:)
        [row.id, row.dom_id(todo, :edit)]
      end
    end

    it_behaves_like "runs inside a non-main Ractor", inputs: [7]
  end

  context "when reading the finalized configuration" do
    let(:subject_call) do
      lambda do
        reactive = Phlex::Reactive
        [reactive.action_path, reactive.defer_path, reactive.fragment_path, reactive.flash_target,
         reactive.defer_transport, reactive.defer_token_ttl, reactive.base_controller_name,
         reactive.authorization_errors.map(&:name), reactive.authorization_methods, reactive.param_schemas,
         reactive.param_types.keys, reactive.effects, reactive.verify_authorized, reactive.renderer.name]
      end
    end

    it_behaves_like "runs inside a non-main Ractor"
  end

  context "when upgrading a verified token payload" do
    let(:subject_call) do
      lambda do
        [Phlex::Reactive.upgrade_token({ "c" => "Todo", "v" => Phlex::Reactive::TOKEN_VERSION }),
         Phlex::Reactive.upgrade_token({ "c" => "Legacy" }),
         Phlex::Reactive.upgrade_token({ "c" => "Future", "v" => Phlex::Reactive::TOKEN_VERSION + 1 })]
      end
    end

    it_behaves_like "runs inside a non-main Ractor"
  end

  context "when signing and verifying an identity token", pending: RactorCanary::SIGN_PENDING do
    let(:subject_call) { -> { Phlex::Reactive.verify(Phlex::Reactive.sign({ "c" => "Todo", "s" => { "n" => 1 } })) } }

    it_behaves_like "runs inside a non-main Ractor"
  end

  context "when rendering a component", pending: RactorCanary::RENDER_PENDING do
    let(:subject_call) { -> { RactorCanary::TodoRow.new(todo: RactorCanary::Todo.new(7)).call } }

    it_behaves_like "runs inside a non-main Ractor"
  end
end
