# frozen_string_literal: true

require "rails_helper"

# Issue #82: verbose_errors — diagnostic endpoint error bodies + dropped-param
# logging. The contract: statuses NEVER change with the flag; the warn log
# always fires (dev AND prod); the plain-text body appears only when the flag
# is on. The default is Rails.env.local? (development AND test), so the flag is
# ON for this suite unless an example sets it explicitly.
RSpec.describe "verbose_errors diagnostics (issue #82)", type: :request do
  # Restore the lazy default after every example — remove the ivar entirely so
  # an explicit `= false` from one example never leaks into the next.
  around do
    it.run
  ensure
    if Phlex::Reactive.instance_variable_defined?(:@verbose_errors)
      Phlex::Reactive.remove_instance_variable(:@verbose_errors)
    end
  end

  before { allow(Rails.logger).to receive(:warn).and_call_original }

  def post_raw(token:, act: "toggle", params: {})
    post "/reactive/actions",
      params: { token:, act:, params: }.to_json,
      headers: { "Content-Type" => "application/json", "Accept" => "text/vnd.turbo-stream.html" }
  end

  describe "the config default" do
    it "defaults to true in the test environment (Rails.env.local? includes test)" do
      expect(Phlex::Reactive.verbose_errors).to be(true)
    end

    it "lets an explicit false stick (no ||= re-defaulting)" do
      Phlex::Reactive.verbose_errors = false
      expect(Phlex::Reactive.verbose_errors).to be(false)
    end
  end

  describe "tampered token -> 400 :tampered" do
    it "renders the diagnostic body when verbose" do
      post_raw(token: "not.a.real.token")

      expect(response).to have_http_status(:bad_request)
      expect(response.body).to include("token signature invalid")
      expect(response.body).to include("secret_key_base mismatch")
    end

    it "keeps the 400 with an empty body when the flag is off, but still warns" do
      Phlex::Reactive.verbose_errors = false
      post_raw(token: "not.a.real.token")

      expect(response).to have_http_status(:bad_request)
      expect(response.body).to be_empty
      expect(Rails.logger).to have_received(:warn)
        .with(a_string_including("[phlex-reactive]", "token signature invalid"))
    end
  end

  describe "unknown token class -> 400 :unknown_class" do
    it "names the class that no longer resolves" do
      post_raw(token: Phlex::Reactive.sign({ "c" => "VanishedComponent" }))

      expect(response).to have_http_status(:bad_request)
      expect(response.body).to include("token class VanishedComponent does not resolve")
      expect(Rails.logger).to have_received(:warn)
        .with(a_string_including("[phlex-reactive]", "VanishedComponent"))
    end

    it "sets the :unknown_class diagnostic on the raised InvalidToken" do
      error = Phlex::Reactive::InvalidToken.new("x", diagnostic: :unknown_class)
      expect(error.diagnostic).to eq(:unknown_class)
    end

    it "keeps the 400 with an empty body when the flag is off" do
      Phlex::Reactive.verbose_errors = false
      post_raw(token: Phlex::Reactive.sign({ "c" => "VanishedComponent" }))

      expect(response).to have_http_status(:bad_request)
      expect(response.body).to be_empty
    end
  end

  describe "resolved-but-not-reactive class -> 400 :not_reactive_class" do
    it "says the class does not include the Component mixin" do
      post_raw(token: Phlex::Reactive.sign({ "c" => "Todo" }))

      expect(response).to have_http_status(:bad_request)
      expect(response.body).to include("Todo resolved but does not include Phlex::Reactive::Component")
    end

    it "keeps the 400 with an empty body when the flag is off" do
      Phlex::Reactive.verbose_errors = false
      post_raw(token: Phlex::Reactive.sign({ "c" => "Todo" }))

      expect(response).to have_http_status(:bad_request)
      expect(response.body).to be_empty
    end
  end

  describe "undeclared action -> 403 (default-deny)" do
    let!(:todo) { Todo.create!(title: "x", done: false) }

    it "names the missing action and lists the declared ones" do
      post_action(TodoItemComponent, payload: { "gid" => todo.to_gid.to_s }, act: "togle")

      expect(response).to have_http_status(:forbidden)
      expect(response.body).to include("action :togle is not declared on TodoItemComponent")
      expect(response.body).to include("declared actions:")
      expect(response.body).to include("toggle").and include("rename")
      expect(Rails.logger).to have_received(:warn)
        .with(a_string_including("[phlex-reactive]", ":togle is not declared"))
    end

    it "keeps the 403 with an empty body when the flag is off" do
      Phlex::Reactive.verbose_errors = false
      post_action(TodoItemComponent, payload: { "gid" => todo.to_gid.to_s }, act: "togle")

      expect(response).to have_http_status(:forbidden)
      expect(response.body).to be_empty
    end
  end

  describe "registered authorization error -> 403" do
    before { Phlex::Reactive.authorization_errors << ModeratedComponent::NotAllowed }
    after { Phlex::Reactive.authorization_errors.delete(ModeratedComponent::NotAllowed) }

    it "names the raised error class and the action, and reminds where to authorize" do
      post_action(ModeratedComponent, payload: { "s" => { "noop" => nil } }, act: "moderate")

      expect(response).to have_http_status(:forbidden)
      expect(response.body).to include("ModeratedComponent::NotAllowed raised in ModeratedComponent#moderate")
      expect(response.body).to include("the signature proves identity, not permission; authorize in the action")
    end

    it "keeps the 403 with an empty body when the flag is off, but still warns" do
      Phlex::Reactive.verbose_errors = false
      post_action(ModeratedComponent, payload: { "s" => { "noop" => nil } }, act: "moderate")

      expect(response).to have_http_status(:forbidden)
      expect(response.body).to be_empty
      expect(Rails.logger).to have_received(:warn)
        .with(a_string_including("[phlex-reactive]", "ModeratedComponent#moderate"))
    end
  end

  describe "missing record -> 404" do
    it "names the gid that no longer resolves" do
      todo = Todo.create!(title: "gone", done: false)
      gid = todo.to_gid.to_s
      todo.destroy!

      post_action(TodoItemComponent, payload: { "gid" => gid }, act: "toggle")

      expect(response).to have_http_status(:not_found)
      expect(response.body).to include(gid)
    end

    it "keeps the 404 with an empty body when the flag is off" do
      Phlex::Reactive.verbose_errors = false
      todo = Todo.create!(title: "gone", done: false)
      gid = todo.to_gid.to_s
      todo.destroy!

      post_action(TodoItemComponent, payload: { "gid" => gid }, act: "toggle")

      expect(response).to have_http_status(:not_found)
      expect(response.body).to be_empty
    end
  end

  describe "dropped-param logging" do
    let(:payload) { { "s" => { "received" => nil } } }

    it "logs an undeclared key with the component + action" do
      post_action(NestedParamsComponent, payload:, act: "save",
        params: { date: "2026-01-02", admin: "true" })

      expect(response).to have_http_status(:ok)
      expect(Rails.logger).to have_received(:warn)
        .with(a_string_including("[phlex-reactive]", "NestedParamsComponent#save dropped params:",
          "admin (undeclared)"))
    end

    it "logs an undeclared NESTED key with its full bracketed path" do
      post_action(NestedParamsComponent, payload:, act: "save",
        params: { invoice_items_attributes: [{ id: "1", quantity: "2", price: "3", _destroy: "false",
                                               secret: "x" }] })

      expect(Rails.logger).to have_received(:warn)
        .with(a_string_including("invoice_items_attributes[0][secret] (undeclared)"))
    end

    it "logs a declared key whose value could not be coerced as uncoercible" do
      post_action(NestedParamsComponent, payload:, act: "save",
        params: { bank_account_ids: "5" })

      expect(Rails.logger).to have_received(:warn)
        .with(a_string_including("bank_account_ids (uncoercible)"))
    end

    it "logs a dropped ARRAY ELEMENT with its bracketed index as uncoercible" do
      # A forged non-file element in a [:file] array is rejected element-wise;
      # the diagnostic must name the element (pages[0]), not just the key.
      document = Document.create!(title: "untitled")

      post_action(DocumentUploadComponent, payload: { "gid" => document.to_gid.to_s },
        act: "upload_pages", params: { pages: ["not-a-file"] })

      expect(response).to have_http_status(:ok)
      expect(Rails.logger).to have_received(:warn)
        .with(a_string_including("pages[0] (uncoercible)"))
    end

    it "logs params posted to an action that declares NO schema" do
      # Forgetting `params:` on the declaration entirely is the loudest version
      # of the silent drop — auto-collected fields vanish with no trace.
      post_action(CounterComponent, payload: { "s" => { "count" => 1 } }, act: "increment",
        params: { stray: "x" })

      expect(response).to have_http_status(:ok)
      expect(Rails.logger).to have_received(:warn)
        .with(a_string_including("CounterComponent#increment dropped params:",
          "stray (undeclared — the action declares no params)"))
    end

    it "logs nothing for a schema-less action when nothing was posted" do
      post_action(CounterComponent, payload: { "s" => { "count" => 1 } }, act: "increment")

      expect(Rails.logger).not_to have_received(:warn).with(a_string_including("dropped params"))
    end

    it "hints when a bracketed name matches a key the schema declares at top level" do
      # The client posted invoice[date] but `save` declares :date FLAT — the
      # #16/#21 confusion this diagnostic exists for.
      post_action(NestedParamsComponent, payload:, act: "save",
        params: { "invoice[date]" => "2026-01-02" })

      expect(Rails.logger).to have_received(:warn)
        .with(a_string_including("invoice[date] (undeclared — schema declares :date at top level"))
    end

    it "hints when a flat name matches a key declared NESTED in the schema" do
      # save_invoice declares :status under :invoice; a flat `status` is the
      # vice-versa confusion.
      post_action(NestedParamsComponent, payload:, act: "save_invoice",
        params: { status: "open" })

      expect(Rails.logger).to have_received(:warn)
        .with(a_string_including("status (undeclared — schema declares :status nested under :invoice"))
    end

    it "hints for a bracketed name against a schema written with STRING keys" do
      # `compile` keeps the keys the author wrote, so a string-keyed declaration
      # is as valid as a symbol one — and a hint that reads only symbols goes
      # quiet for half of them, exactly where the #16/#21 confusion is hardest
      # to see.
      post_action(NestedParamsComponent, payload:, act: "save_string_schema",
        params: { "invoice[date]" => "2026-01-02" })

      expect(Rails.logger).to have_received(:warn)
        .with(a_string_including("invoice[date] (undeclared — schema declares :date at top level"))
    end

    it "hints for a flat name against a nested schema written with STRING keys" do
      post_action(NestedParamsComponent, payload:, act: "save_string_schema",
        params: { status: "open" })

      expect(Rails.logger).to have_received(:warn)
        .with(a_string_including("status (undeclared — schema declares :status nested under :invoice"))
    end

    it "logs nothing about dropped params when the flag is off" do
      Phlex::Reactive.verbose_errors = false
      post_action(NestedParamsComponent, payload:, act: "save",
        params: { date: "2026-01-02", admin: "true" })

      expect(response).to have_http_status(:ok)
      expect(Rails.logger).not_to have_received(:warn).with(a_string_including("dropped params"))
    end

    it "logs nothing when nothing was dropped" do
      post_action(NestedParamsComponent, payload:, act: "save", params: { date: "2026-01-02" })

      expect(Rails.logger).not_to have_received(:warn).with(a_string_including("dropped params"))
    end
  end
end
