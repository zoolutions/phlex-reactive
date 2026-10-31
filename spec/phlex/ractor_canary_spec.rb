# frozen_string_literal: true

require "rails_helper"

# What the Ractor blocks below reach through constants: a Ractor block must be
# capture-free, so everything it touches is a constant or an input.
module RactorCanary
  SCHEMA = Ractor.make_shareable(
    { count: :integer, title: :string, done: :boolean, on: :date, tags: [:string], address: { street: :string },
      quantity: :strict_integer, weight: :strict_float }
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

  # A reactive component as an app writes one: signed state and an action
  # that takes params. Boot warms it (Component::Registry.warm!), so a request
  # reads everything it dispatches and signs with off the class. (Not named
  # like the dummy's CounterComponent, which the MCP find spec ranks first.)
  class Tally < ApplicationComponent
    include Phlex::Reactive::Component

    reactive_state :total
    action :add, params: { amount: :integer }

    def initialize(total: 0) = @total = total
    def id = "ractor-canary-tally"
    def add(amount: 1) = @total += amount
    def view_template = div(**reactive_root) { @total.to_s }
  end

  RENDER_PENDING = "Phlex 2.4.1 reads its non-shareable Phlex::ATTRIBUTE_CACHE constant on every element " \
                   "with attributes; a per-Ractor cache is pending upstream (yippee-fun/phlex#1055)"

  SIGN_PENDING = "Phlex::Reactive.verifier is an ActiveSupport::MessageVerifier, which is not Ractor-shareable " \
                 "and which ActiveSupport cannot build or use outside the main Ractor either (Messages::Codec's " \
                 "class attributes and Messages::Metadata::ENVELOPE_SERIALIZERS are not shareable, ActiveSupport 8.1)"

  # A reactive root renders its signed token: both of the above.
  REACTIVE_RENDER_PENDING = "#{RENDER_PENDING}; and it signs its token: #{SIGN_PENDING}".freeze
end

# Tier 3 of conformance-kit, on Ruby 4.0 (skipped below it with the kit's
# reason): with the configuration finalized, phlex-reactive's pure operations
# run inside a non-main Ractor and agree with the main Ractor
# (zoolutions/phlex-reactive#364). What cannot run there yet is pending with
# its upstream reason, and fails the day it starts to pass.
RSpec.describe "phlex-reactive inside a non-main Ractor" do # rubocop:disable RSpec/DescribeClass
  # Other examples reset the param-type registry; finalize! is what boot does.
  # Its frozen copies replace the module's settings: put the originals back
  # so no later example finds them frozen.
  around do
    reactive = Phlex::Reactive
    snapshot = reactive.instance_variables.to_h { [it, reactive.instance_variable_get(it)] }
    reactive.finalize!
    it.run
  ensure
    (reactive.instance_variables - snapshot.keys).each { reactive.remove_instance_variable(it) }
    snapshot.each { |ivar, value| reactive.instance_variable_set(ivar, value) }
  end

  context "when coercing params through a compiled schema" do
    let(:subject_call) do
      -> { Phlex::Reactive::ParamSchema.compile(RactorCanary::SCHEMA).coerce(it) }
    end

    it_behaves_like "runs inside a non-main Ractor", inputs: [{
      "count" => "3", "title" => 4, "done" => "1", "on" => "2026-10-15",
      "tags" => ["a", 1], "address" => { "street" => 5 }, "junk" => "dropped",
      "quantity" => "15", "weight" => "1.5"
    }]
    it_behaves_like "runs inside a non-main Ractor", inputs: [{
      "count" => "x", "on" => "not a date", "tags" => "nope", "quantity" => "", "weight" => "0x10"
    }]
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

  context "when reading a warmed component's actions and state" do
    before { Phlex::Reactive::Component::Registry.warm!([RactorCanary::Tally]) }

    let(:subject_call) do
      lambda do
        tally = RactorCanary::Tally
        add = tally.reactive_actions.fetch(:add)
        [tally.reactive_actions.keys, add.params, add.schema.coerce(it), tally.reactive_state_keys,
         tally.reactive_state_ivars, tally.reactive_record_ivar, tally.reactive_effect_attrs,
         tally.reactive_on_complete_attr, tally.skip_verify_authorized?(:add)]
      end
    end

    it_behaves_like "runs inside a non-main Ractor", inputs: [{ "amount" => "2", "junk" => "dropped" }]
  end

  context "when signing and verifying an identity token", pending: RactorCanary::SIGN_PENDING do
    let(:subject_call) { -> { Phlex::Reactive.verify(Phlex::Reactive.sign({ "c" => "Todo", "s" => { "n" => 1 } })) } }

    it_behaves_like "runs inside a non-main Ractor"
  end

  context "when rendering a component", pending: RactorCanary::RENDER_PENDING do
    let(:subject_call) { -> { RactorCanary::TodoRow.new(todo: RactorCanary::Todo.new(7)).call } }

    it_behaves_like "runs inside a non-main Ractor"
  end

  context "when rendering a warmed reactive component", pending: RactorCanary::REACTIVE_RENDER_PENDING do
    before { Phlex::Reactive::Component::Registry.warm!([RactorCanary::Tally]) }

    let(:subject_call) { -> { RactorCanary::Tally.new(total: 2).call } }

    it_behaves_like "runs inside a non-main Ractor"
  end
end
