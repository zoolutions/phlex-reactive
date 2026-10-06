# frozen_string_literal: true

# `::MCP` (the optional gem) is NOT redundant here — this file's describe scope is
# Phlex::Reactive::MCP, so a bare `MCP` would resolve to OUR module, not the gem.
# rubocop:disable Style/RedundantConstantBase

require "rails_helper"

# The read-only diagnostic MCP server (issue #168): a stdio server exposing five
# read-only tools (doctor, components, actions, find, config) so Claude Code
# inside a host app can introspect the live registry. The `mcp` gem is OPTIONAL
# and lazy — Phlex::Reactive::MCP.load! requires it on demand with a helpful
# message when missing (the pgbus pattern). These specs load it and exercise each
# tool's JSON shape, plus a leak spec proving no secret ever reaches the output.
RSpec.describe Phlex::Reactive::MCP do
  describe ".load!" do
    it "raises a helpful Phlex::Reactive::Error when the mcp gem is missing" do
      # Simulate the gem being absent: make `require "mcp"` raise LoadError.
      # (We don't actually uninstall it — the message + error class is the
      # contract.) An internal require path is NOT rescued, so a typo there
      # surfaces verbatim rather than masquerading as "add the mcp gem".
      allow(described_class).to receive(:require).and_call_original
      allow(described_class).to receive(:require).with("mcp").and_raise(LoadError)

      expect { described_class.load! }
        .to raise_error(Phlex::Reactive::Error, /mcp.*gem|gem.*mcp/i)
    end

    it "is idempotent (loads the tool tree without raising when the gem is present)" do
      expect { described_class.load! }.not_to raise_error
      expect { described_class.load! }.not_to raise_error
    end
  end

  # Everything below needs the real gem loaded (available in the dev/test bundle).
  context "with the mcp gem loaded", if: defined?(::MCP) || (begin
    require "mcp"
    true
  rescue LoadError
    false
  end) do
    before do
      described_class.load!
      Rails.application.eager_load!
    end

    # Every tool call returns an MCP::Tool::Response whose single text-content
    # block is a JSON string. Decode it for assertions.
    def tool_json(tool, **)
      response = tool.call(server_context: nil, **)
      text = response.content.first[:text]
      JSON.parse(text)
    end

    describe "the server" do
      subject(:server) { described_class::Server.build }

      it "builds an MCP::Server with a fixed tool array" do
        expect(server).to be_a(::MCP::Server)
      end

      it "exposes exactly the five read-only tools" do
        names = described_class::Server::TOOLS.map(&:tool_name)
        expect(names).to contain_exactly(
          "phlex_reactive_doctor",
          "phlex_reactive_components",
          "phlex_reactive_actions",
          "phlex_reactive_find",
          "phlex_reactive_config"
        )
      end

      it "marks every tool read-only and non-destructive" do
        described_class::Server::TOOLS.each do
          annotations = it.annotations_value
          expect(annotations.read_only_hint).to be(true)
          expect(annotations.destructive_hint).to be(false)
        end
      end
    end

    describe "phlex_reactive_doctor" do
      it "returns the doctor checks as structured JSON" do
        result = tool_json(described_class::Tools::DoctorTool)
        expect(result["checks"]).to be_an(Array)
        check = result["checks"].first
        expect(check.keys).to include("name", "status", "message")
      end
    end

    describe "phlex_reactive_components" do
      it "returns a component summary (name, path, action count, keys)" do
        result = tool_json(described_class::Tools::ComponentsTool)
        counter = result["components"].find { it["name"] == "CounterComponent" }
        expect(counter).not_to be_nil
        expect(counter["action_count"]).to be_positive
        expect(counter["state_keys"]).to include("count")
      end
    end

    describe "phlex_reactive_actions" do
      it "returns the full inventory with params, source location, authorization" do
        result = tool_json(described_class::Tools::ActionsTool)
        counter = result["components"].find { it["component"] == "CounterComponent" }
        set_action = counter["actions"].find { it["name"] == "set" }
        expect(set_action["params"]).to eq({ "count" => "integer" })
        expect(set_action).to have_key("source_location")
        expect(set_action).to have_key("authorization_call_detected")
      end

      it "reports the three-state authorization and the skip form (issue #278)" do
        result = tool_json(described_class::Tools::ActionsTool)
        todo = result["components"].find { it["component"] == "AuthorizedTodoComponent" }
        skipped = todo["actions"].find { it["name"] == "rename_skipped" }
        public = result["components"].find { it["component"] == "PublicCounterComponent" }
        public_inc = public["actions"].find { it["name"] == "increment" }

        expect(skipped).to include("authorization" => "skipped", "authorization_skip" => "action")
        expect(public_inc).to include("authorization" => "skipped", "authorization_skip" => "class")
      end

      it "lists a subclass of a reactive component with its inherited skip (issue #302)" do
        result = tool_json(described_class::Tools::ActionsTool, component: "InheritedSkipComponent")
        sub = result["components"].find { it["component"] == "InheritedSkipComponent" }

        expect(sub).not_to be_nil
        expect(sub["actions"].map { it["name"] }).to include("increment", "reset")
        expect(sub["actions"]).to all(include("authorization" => "skipped", "authorization_skip" => "class"))
      end

      it "filters to one component when given component:" do
        result = tool_json(described_class::Tools::ActionsTool, component: "CounterComponent")
        names = result["components"].map { it["component"] }
        expect(names).to eq(["CounterComponent"])
      end
    end

    describe "phlex_reactive_find" do
      it "returns ranked matches with action detail incl. method definitions" do
        result = tool_json(described_class::Tools::FindTool, query: "counter")
        top = result["matches"].first
        expect(top["name"]).to eq("CounterComponent")
        increment = top["actions"].find { it["name"] == "increment" }
        expect(increment["definition"]).to include("def increment")
      end

      it "reports the three-state authorization per action (issue #278)" do
        result = tool_json(described_class::Tools::FindTool, query: "PublicCounterComponent")
        increment = result["matches"].first["actions"].find { it["name"] == "increment" }
        expect(increment).to include("authorization" => "skipped", "authorization_skip" => "class")
      end

      it "reports no matches for an unknown query" do
        result = tool_json(described_class::Tools::FindTool, query: "zzz_no_such_zzz")
        expect(result["matches"]).to eq([])
      end
    end

    describe "phlex_reactive_config" do
      it "returns a redacted config summary" do
        result = tool_json(described_class::Tools::ConfigTool)
        expect(result["version"]).to eq(Phlex::Reactive::VERSION)
        expect(result).to include("action_path", "base_controller_name", "verify_authorized",
          "authorization_methods", "pgbus", "pgbus_streams")
        expect(result["verify_authorized"]).to be_in([true, false])
      end

      it "never includes the verifier, secret_key_base, or a signed token" do
        result = tool_json(described_class::Tools::ConfigTool)
        serialized = result.to_json
        expect(serialized).not_to include(Rails.application.secret_key_base)
        expect(serialized).not_to include("verifier")
        expect(serialized.downcase).not_to include("secret_key_base")
      end
    end

    describe "no tool leaks a secret" do
      it "no tool's serialized output contains secret_key_base or a signed token" do
        secret = Rails.application.secret_key_base
        token = Phlex::Reactive.sign("c" => "CounterComponent", "s" => { "count" => 1 })

        outputs = [
          tool_json(described_class::Tools::DoctorTool),
          tool_json(described_class::Tools::ComponentsTool),
          tool_json(described_class::Tools::ActionsTool),
          tool_json(described_class::Tools::FindTool, query: "counter"),
          tool_json(described_class::Tools::ConfigTool)
        ].map(&:to_json).join

        expect(outputs).not_to include(secret)
        expect(outputs).not_to include(token)
      end
    end
  end
end
# rubocop:enable Style/RedundantConstantBase
