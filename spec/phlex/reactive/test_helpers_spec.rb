# frozen_string_literal: true

require "rails_helper"

# The public Phlex::Reactive::TestHelpers (issue #110): a no-HTTP `run_reactive`
# driver, its Result wrapper, token minting, and RSpec matchers. The driver's
# whole point is that it goes THROUGH the endpoint's security contract — default
# deny, signed identity round-trip (record re-find), schema coercion, the same
# transaction wrapper — so a unit test can't validate a component that would fail
# at the real endpoint. These specs lock exactly that.
RSpec.describe Phlex::Reactive::TestHelpers do
  # Mix the module into these examples the way a downstream app would
  # (config.include Phlex::Reactive::TestHelpers). The driver needs no request
  # type; the HTTP helpers do (covered by the dogfooded request suite).
  include described_class

  let(:todo) { Todo.create!(title: "write docs", done: false) }

  describe "#reactive_token_for" do
    it "mints a verifiable token from a CLASS (public sign path, no state)" do
      token = reactive_token_for(CounterComponent)
      payload = Phlex::Reactive.verify(token)

      expect(payload["c"]).to eq("CounterComponent")
    end

    it "merges an explicit payload into the class-form token" do
      token = reactive_token_for(TodoItemComponent, "gid" => todo.to_gid.to_s)
      payload = Phlex::Reactive.verify(token)

      expect(payload["c"]).to eq("TodoItemComponent")
      expect(payload["gid"]).to eq(todo.to_gid.to_s)
    end

    it "mints from an INSTANCE by wrapping the private reactive_token (state signed)" do
      payload = Phlex::Reactive.verify(reactive_token_for(CounterComponent.new(count: 7)))

      expect(payload["c"]).to eq("CounterComponent")
      expect(payload.dig("s", "count")).to eq(7)
    end

    it "signs an instance-form record component's gid" do
      payload = Phlex::Reactive.verify(reactive_token_for(TodoItemComponent.new(todo:)))

      expect(payload["gid"]).to eq(todo.to_gid.to_s)
    end
  end

  describe "#run_reactive — the no-HTTP driver" do
    context "with default-deny (only declared actions run)" do
      it "raises UndeclaredReactiveAction for an undeclared action" do
        expect { run_reactive(CounterComponent.new(count: 1), :drop_table) }
          .to raise_error(Phlex::Reactive::TestHelpers::UndeclaredReactiveAction, /drop_table/)
      end

      it "names the declared actions in the error (a readable message)" do
        expect { run_reactive(CounterComponent.new(count: 1), :nope) }
          .to raise_error(Phlex::Reactive::TestHelpers::UndeclaredReactiveAction, /increment/)
      end
    end

    context "with identity round-trip (sign -> verify -> from_identity)" do
      it "re-finds the record so the action runs against the DB row" do
        result = run_reactive(TodoItemComponent.new(todo:), :toggle)

        expect(todo.reload.done?).to be(true)
        expect(result).to be_replace
      end

      it "raises RecordNotFound for a stale gid (the endpoint's 404 equivalent)" do
        component = TodoItemComponent.new(todo:)
        todo.destroy!

        expect { run_reactive(component, :toggle) }
          .to raise_error(ActiveRecord::RecordNotFound)
      end
    end

    context "with schema coercion (declared params cast; undeclared dropped)" do
      it "casts a declared :integer param before the method sees it" do
        # The client always sends strings; the schema declares count: :integer.
        # The action runs against the REBUILT instance (identity round-trip), so
        # assert on result.component, not the original.
        result = run_reactive(CounterComponent.new(count: 0), :set, count: "42")

        expect(result.component.instance_variable_get(:@count)).to eq(42)
      end

      it "drops an undeclared param (no raw mass assignment)" do
        # :increment declares NO params; a stray key must never reach it (a
        # TypeError/ArgumentError would prove it leaked through as a kwarg).
        result = nil
        expect { result = run_reactive(CounterComponent.new(count: 0), :increment, injected: "x") }
          .not_to raise_error
        expect(result.component.instance_variable_get(:@count)).to eq(1)
      end
    end

    context "with a registered authorization error" do
      it "SURFACES a registered authorization error by raising (unit-test contract)" do
        # CounterComponent#boom raises CounterComponent::Denied, registered in the
        # dummy app's authorization_errors. The endpoint maps it to 403; the
        # driver raises it so a unit test can assert on the real exception.
        expect { run_reactive(CounterComponent.new(count: 1), :boom) }
          .to raise_error(CounterComponent::Denied)
      end
    end

    context "with the transaction wrapper" do
      it "runs the action inside a DB transaction (matches the endpoint)" do
        component = TodoItemComponent.new(todo:)
        expect(ActiveRecord::Base).to receive(:transaction).and_call_original

        run_reactive(component, :toggle)
      end
    end

    # Issue #370: held: stands in for the X-Reactive-Held header, filtered the
    # same way (to the action's declared params).
    context "with held:" do
      it "exposes the held names to the action as reactive_held_fields, filtered to its params" do
        component = HeldNoteComponent.new(todo:)

        result = run_reactive(component, :save, held: %w[title is_admin], title: "mine")

        expect(result.component.instance_variable_get(:@held)).to eq(["title"])
        expect(result.component.instance_variable_get(:@conflict)).to eq("mine")
        expect(todo.reload.title).to eq("write docs")
        expect(Phlex::Reactive::HeldFields.current).to eq([])
      end

      it "is [] without held:" do
        result = run_reactive(HeldNoteComponent.new(todo:), :save, title: "mine")

        expect(result.component.instance_variable_get(:@held)).to eq([])
        expect(todo.reload.title).to eq("mine")
      end
    end
  end

  describe "Result" do
    it "wraps a Response.replace as replace? (and exposes streams)" do
      result = run_reactive(TodoItemComponent.new(todo:), :toggle)

      expect(result).to be_replace
      expect(result).not_to be_remove
      expect(result).not_to be_redirect
      expect(result.streams).to be_an(Array)
      expect(result.streams.join).to include(%(target="#{ActionView::RecordIdentifier.dom_id(todo)}"))
    end

    it "reports remove? for Response.remove and carries NO replace" do
      result = run_reactive(TodoItemComponent.new(todo:), :archive)

      expect(result).to be_remove
      expect(result).not_to be_replace
      expect(result.streams.join).to include(%(action="remove"))
    end

    it "reports redirect? + redirect_url for Response.redirect" do
      result = run_reactive(CounterComponent.new(count: 0), :go_home)

      expect(result).to be_redirect
      expect(result.redirect_url).to eq("/todos")
    end

    it "treats a LEGACY arbitrary return value as an implicit replace" do
      # :increment returns the Integer @count (the legacy contract — value
      # ignored by the endpoint, which falls back to the single self-replace).
      result = run_reactive(CounterComponent.new(count: 0), :increment)

      expect(result).to be_replace
      expect(result).not_to be_remove
      expect(result.response).to be_nil # no Response object was returned
    end

    it "exposes the returned Response object when the action returned one" do
      result = run_reactive(TodoItemComponent.new(todo:), :archive)

      expect(result.response).to be_a(Phlex::Reactive::Response)
    end
  end

  describe "matchers" do
    describe "have_reactive_replace" do
      it "passes a Result that replaces the given component" do
        result = run_reactive(TodoItemComponent.new(todo:), :toggle)
        expect(result).to have_reactive_replace(TodoItemComponent.new(todo:))
      end

      it "also accepts a bare DOM id" do
        result = run_reactive(CounterComponent.new(count: 0), :increment)
        expect(result).to have_reactive_replace("counter")
      end

      it "fails with a readable message when the target id doesn't match" do
        result = run_reactive(CounterComponent.new(count: 0), :increment)
        expect { expect(result).to have_reactive_replace("not-counter") }
          .to raise_error(RSpec::Expectations::ExpectationNotMetError, /not-counter/)
      end
    end

    describe "have_reactive_remove" do
      it "passes a Result that removes the given component" do
        result = run_reactive(TodoItemComponent.new(todo:), :archive)
        expect(result).to have_reactive_remove(TodoItemComponent.new(todo:))
      end

      it "fails readably against a replace result" do
        result = run_reactive(CounterComponent.new(count: 0), :increment)
        expect { expect(result).to have_reactive_remove("counter") }
          .to raise_error(RSpec::Expectations::ExpectationNotMetError, /remove/)
      end
    end

    describe "have_reactive_token_for (pins the #44/#46 token-refresh regression)" do
      it "passes when the reply refreshes the component's signed token" do
        result = run_reactive(CounterComponent.new(count: 0), :increment)
        expect(result).to have_reactive_token_for(CounterComponent.new(count: 1))
      end

      it "also accepts a bare DOM id (the documented component-or-id contract)" do
        result = run_reactive(CounterComponent.new(count: 0), :increment)
        expect(result).to have_reactive_token_for("counter")
      end

      it "fails readably when NO fresh token for the component is present" do
        result = run_reactive(TodoItemComponent.new(todo:), :archive) # remove: no token
        expect { expect(result).to have_reactive_token_for(TodoItemComponent.new(todo:)) }
          .to raise_error(RSpec::Expectations::ExpectationNotMetError, /token/)
      end
    end
  end
end
