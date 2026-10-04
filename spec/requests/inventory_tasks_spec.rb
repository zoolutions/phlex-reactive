# frozen_string_literal: true

require "rails_helper"
require "rake"

# The `phlex_reactive:actions` and `phlex_reactive:find[query]` rake tasks ship
# in lib/tasks and are auto-loaded by the Rails engine in a host app (issue #168).
# They surface the Inspector's read-only inventory as plain text (FORMAT=json for
# machine consumption), the same no-ANSI posture as the doctor. Here we load the
# .rake file against the booted dummy app and drive each task.
RSpec.describe "phlex_reactive inventory rake tasks" do
  let(:rake) do
    app = Rake::Application.new
    Rake.application = app
    Rake::Task.define_task(:environment) # already booted; the task just depends on it
    load File.expand_path("../../lib/tasks/phlex_reactive.rake", __dir__)
    app
  end

  before { Rails.application.eager_load! }

  after do
    Rake.application = Rake::Application.new
    ENV.delete("FORMAT")
    ENV.delete("UNVERIFIED")
  end

  describe "phlex_reactive:actions" do
    it "is defined" do
      rake
      expect(Rake::Task.task_defined?("phlex_reactive:actions")).to be(true)
    end

    it "prints a plain-text table naming a component and its actions (no ANSI color)" do
      output = capture_stdout { rake["phlex_reactive:actions"].invoke }
      expect(output).to include("CounterComponent")
      expect(output).to include("increment")
      expect(output).not_to match(/\e\[[0-9;]*m/) # no ANSI escapes
    end

    it "shows the declared param schema for an action that takes params" do
      output = capture_stdout { rake["phlex_reactive:actions"].invoke }
      # CounterComponent declares `action :set, params: { count: :integer }`.
      expect(output).to match(/set.*count/m)
    end

    it "emits parseable JSON when FORMAT=json" do
      ENV["FORMAT"] = "json"
      output = capture_stdout { rake["phlex_reactive:actions"].invoke }
      parsed = JSON.parse(output)
      counter = parsed.find { it["component"] == "CounterComponent" }
      expect(counter).not_to be_nil
      action_names = counter["actions"].map { it["name"] }
      expect(action_names).to include("increment", "set")
    end

    # Issue #278: three AUTH states — a deliberate skip is not "unverified".
    describe "the AUTH column" do
      def row(output, component, action)
        output.lines.find { it.start_with?("#{component} ") && it.split[1] == action }.to_s
      end

      let(:output) { capture_stdout { rake["phlex_reactive:actions"].invoke } }

      it "prints authorized* for an action with a detected authorization call" do
        expect(row(output, "AuthorizedTodoComponent", "rename")).to end_with("authorized*\n")
      end

      it "prints skipped for an action named in skip_verify_authorized" do
        expect(row(output, "AuthorizedTodoComponent", "rename_skipped")).to end_with("skipped\n")
      end

      it "prints skipped (class) for every action of a bare skip_verify_authorized component" do
        expect(row(output, "PublicCounterComponent", "increment")).to end_with("skipped (class)\n")
      end

      it "prints unverified for an action with neither" do
        expect(row(output, "AuthorizedTodoComponent", "rename_unguarded")).to end_with("unverified\n")
      end
    end

    describe "UNVERIFIED=1" do
      it "lists only the unverified rows" do
        ENV["UNVERIFIED"] = "1"
        output = capture_stdout { rake["phlex_reactive:actions"].invoke }
        rows = output.lines.drop(1)

        expect(rows).not_to be_empty
        expect(rows).to all(end_with("unverified\n"))
        expect(output).to include("rename_unguarded")
        expect(output).not_to include("rename_skipped")
        expect(output).not_to include("PublicCounterComponent")
      end

      it "accepts true/yes as well as 1, case-insensitively" do
        %w[true YES].each do
          ENV["UNVERIFIED"] = it
          rake["phlex_reactive:actions"].reenable
          output = capture_stdout { rake["phlex_reactive:actions"].invoke }
          expect(output.lines.drop(1)).to all(end_with("unverified\n"))
        end
      end

      it "says there are no unverified actions (not 'no components') when the queue is empty" do
        ENV["UNVERIFIED"] = "1"
        public_only = Phlex::Reactive::Inspector.components.select { it.name == "PublicCounterComponent" }
        allow(Phlex::Reactive::Inspector).to receive(:components).and_return(public_only)
        output = capture_stdout { rake["phlex_reactive:actions"].invoke }
        expect(output.strip).to eq("no unverified actions")
      end

      it "filters the JSON to unverified actions and drops components with none" do
        ENV["UNVERIFIED"] = "1"
        ENV["FORMAT"] = "json"
        parsed = JSON.parse(capture_stdout { rake["phlex_reactive:actions"].invoke })

        expect(parsed).not_to be_empty
        expect(parsed.flat_map { it["actions"] }.map { it["authorization"] }).to all(eq("none"))
        expect(parsed.map { it["component"] }).not_to include("PublicCounterComponent")
        expect(parsed).to all(satisfy { it["actions"].any? })
      end
    end

    it "adds authorization + authorization_skip to the JSON, keeping authorization_call_detected" do
      ENV["FORMAT"] = "json"
      parsed = JSON.parse(capture_stdout { rake["phlex_reactive:actions"].invoke })
      todo = parsed.find { it["component"] == "AuthorizedTodoComponent" }["actions"].index_by { it["name"] }
      public_inc = parsed.find { it["component"] == "PublicCounterComponent" }["actions"].first

      expect(todo["rename"]).to include("authorization" => "detected", "authorization_skip" => nil,
        "authorization_call_detected" => true)
      expect(todo["rename_skipped"]).to include("authorization" => "skipped", "authorization_skip" => "action",
        "authorization_call_detected" => false)
      expect(todo["rename_unguarded"]).to include("authorization" => "none", "authorization_skip" => nil)
      expect(public_inc).to include("authorization" => "skipped", "authorization_skip" => "class")
    end

    it "never leaks a token, secret, or runtime state into the output" do
      ENV["FORMAT"] = "json"
      output = capture_stdout { rake["phlex_reactive:actions"].invoke }
      expect(output).not_to include(Rails.application.secret_key_base)
    end
  end

  describe "phlex_reactive:find[query]" do
    it "is defined" do
      rake
      expect(Rake::Task.task_defined?("phlex_reactive:find")).to be(true)
    end

    it "prints the top match in detail with each action's method definition source" do
      output = capture_stdout { rake["phlex_reactive:find"].invoke("counter") }
      expect(output).to include("CounterComponent")
      # The detail prints the method definition source extracted with Prism.
      expect(output).to include("def increment")
    end

    it "reports no match for an unknown query" do
      output = capture_stdout { rake["phlex_reactive:find"].invoke("zzz_no_such_zzz") }
      expect(output).to match(/no.*match/i)
    end
  end

  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end
end
