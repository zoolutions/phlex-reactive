# frozen_string_literal: true

require "rails_helper"

# verify_authorized's interceptor (issue #168) is prepended at boot when the
# app eager-loads (zoolutions/phlex-reactive#364), so a request never mutates
# a component class: no prepend, no class instance variable written. The lazy
# path stays for development (no eager load), now behind a lock, so two
# threads that first-call it for one class prepend ONE interceptor.
RSpec.describe Phlex::Reactive::Authorization, "boot instrumentation" do
  around do
    previous = [Phlex::Reactive.verify_authorized, Phlex::Reactive.authorization_methods]
    Phlex::Reactive.verify_authorized = true
    it.run
  ensure
    Phlex::Reactive.verify_authorized, Phlex::Reactive.authorization_methods = previous
  end

  # The interceptors are prepended: they sit before the class in its ancestors.
  def interceptors(klass) = klass.ancestors.index(klass)

  def fresh_component
    Class.new(ApplicationComponent) do
      include Phlex::Reactive::Component

      reactive_state :n
      action :bump

      # The app's authorization helper the interceptor wraps (Pundit's name).
      def authorize! = :ok
      def bump = authorize!
    end
  end

  describe ".instrument_all!" do
    it "instruments every reactive component class, once" do
      component = fresh_component
      plain = Class.new(ApplicationComponent) { include Phlex::Reactive::Streamable }

      described_class.instrument_all!([component, plain, component])

      expect(interceptors(component)).to eq(1)
      expect(interceptors(plain)).to eq(0)
      expect(described_class.instrumented?(component)).to be(true)
    end
  end

  describe "Engine.finalize_boot!" do
    around do
      it.run
    ensure
      Phlex::Reactive::Engine.finalize_boot!(eager_load: false)
    end

    it "instruments the registered component classes when the app eager-loads" do
      component = fresh_component

      Phlex::Reactive::Engine.finalize_boot!(eager_load: true)

      expect(described_class.instrumented?(component)).to be(true)
    end

    it "leaves instrumentation to the first request otherwise" do
      component = fresh_component

      Phlex::Reactive::Engine.finalize_boot!(eager_load: false)

      expect(described_class.instrumented?(component)).to be(false)
    end
  end

  describe "a request after boot instrumentation", type: :request do
    it "prepends nothing and marks nothing on the class" do
      described_class.instrument_all!([AuthorizedTodoComponent])
      before = AuthorizedTodoComponent.ancestors
      allow(AuthorizedTodoComponent).to receive(:instance_variable_set).and_call_original
      todo = Todo.create!(title: "orig")

      post_action(AuthorizedTodoComponent, act: "rename",
        payload: { "gid" => todo.to_gid.to_s }, params: { title: "renamed" })

      expect(response).to have_http_status(:ok)
      expect(AuthorizedTodoComponent.ancestors).to eq(before)
      expect(AuthorizedTodoComponent).not_to have_received(:instance_variable_set)
        .with(:@reactive_authorization_instrumented, anything)
    end
  end

  describe "the lazy (development) path" do
    it "prepends one interceptor when two threads first-call it for one class" do
      component = fresh_component
      entered = Queue.new
      release = Queue.new
      calls = 0
      # The race window: between the "already instrumented?" check and the
      # prepend. The first thread to reach it waits there until released.
      allow(Phlex::Reactive).to receive(:authorization_methods) do
        calls += 1
        if calls == 1
          entered << true
          release.pop
        end
        %i[authorize!]
      end

      first = Thread.new { described_class.instrument!(component) }
      entered.pop
      second = Thread.new { described_class.instrument!(component) }
      Thread.pass until second.stop?
      release << true
      [first, second].each(&:join)

      expect(interceptors(component)).to eq(1)
    end
  end
end
