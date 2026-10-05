# frozen_string_literal: true

require "rails_helper"

# The doctor validates the WHOLE install with ✓/✗/? checks (issue #106). It
# boots against the dummy app — a correctly-wired install — so the happy path is
# all-green, and inline fixtures exercise the two component findings that don't
# need a second booted app (a declared-but-missing action, and a state-backed
# class with no #id).
RSpec.describe Phlex::Reactive::Doctor do
  subject(:doctor) { described_class.new }

  # A Check is the small object the issue specifies: it answers [status, message,
  # fix]. status is one of :ok/:fail/:unknown; a passing check has no fix.
  describe "a check" do
    it "exposes status, message and fix" do
      check = Phlex::Reactive::Doctor::Check.new(:ok, "all good", fix: nil)
      expect(check.status).to eq(:ok)
      expect(check.message).to eq("all good")
      expect(check.fix).to be_nil
      expect(check).to be_ok
    end

    it "carries a fix on failure" do
      check = Phlex::Reactive::Doctor::Check.new(:fail, "broken", fix: "do this")
      expect(check).not_to be_ok
      expect(check.fix).to eq("do this")
    end
  end

  describe "#checks (happy path against the dummy app)" do
    before { Rails.application.eager_load! }

    it "returns a check for every section" do
      names = doctor.checks.map(&:name)
      expect(names).to include(
        :route, :stimulus, :csrf, :verifier, :base_controller, :actions, :ids
      )
    end

    it "passes the route check (the endpoint resolves)" do
      route = doctor.checks.find { it.name == :route }
      expect(route).to be_ok
    end

    it "passes the defer-route check (issue #165 — the defer endpoint resolves)" do
      defer_route = doctor.checks.find { it.name == :defer_route }
      expect(defer_route).to be_ok
    end

    it "passes the fragment-route check (issue #277 — the GET fragment endpoint resolves)" do
      fragment_route = doctor.checks.find { it.name == :fragment_route }
      expect(fragment_route).to be_ok
    end

    it "fails the fragment-route check when the path does not reach the gem controller" do
      original = Phlex::Reactive.fragment_path
      Phlex::Reactive.fragment_path = "/shadowed/fragment"
      fragment_route = doctor.checks.find { it.name == :fragment_route }

      expect(fragment_route).not_to be_ok
      expect(fragment_route.fix).to include("Phlex::Reactive.fragment_path")
    ensure
      Phlex::Reactive.fragment_path = original
    end

    it "says nothing about the fragment-path meta while the path is the default" do
      expect(doctor.checks.map(&:name)).not_to include(:fragment_path_meta)
    end

    it "flags a custom fragment_path whose meta tag is in no layout (the client would refuse every URL)" do
      original = Phlex::Reactive.fragment_path
      Phlex::Reactive.fragment_path = "/_r/fragment"
      meta = doctor.checks.find { it.name == :fragment_path_meta }

      expect(meta).not_to be_ok
      expect(meta.fix).to include('<meta name="phlex-reactive-fragment-path"')
    ensure
      Phlex::Reactive.fragment_path = original
    end

    # The layout lives in a scratch app root, NOT the dummy's app/ — a file
    # appearing there would trip Rails' reloader mid-suite.
    describe "the fragment-path meta check against layout files" do
      let(:app_root) { Pathname(Dir.mktmpdir("doctor-fragment-meta")) }
      let(:layout) { app_root.join("app/views/layouts/application.html.erb") }

      around do
        original = Phlex::Reactive.fragment_path
        Phlex::Reactive.fragment_path = "/_r/fragment"
        it.run
      ensure
        Phlex::Reactive.fragment_path = original
        FileUtils.rm_rf(app_root)
      end

      def meta_check(head)
        FileUtils.mkdir_p(layout.dirname)
        File.write(layout, head)
        allow(Rails).to receive(:root).and_return(app_root)
        doctor.checks.find { it.name == :fragment_path_meta }
      end

      it "passes when a layout renders the meta with the configured path" do
        expect(meta_check(%(<meta name="phlex-reactive-fragment-path" content="/_r/fragment">))).to be_ok
      end

      it "passes when a layout renders it from the setting" do
        expect(meta_check(%(<meta name="phlex-reactive-fragment-path" content="<%= Phlex::Reactive.fragment_path %>">)))
          .to be_ok
      end

      it "fails when the meta carries a stale path" do
        expect(meta_check(%(<meta name="phlex-reactive-fragment-path" content="/old/fragment">))).not_to be_ok
      end
    end

    it "passes the verifier round-trip check" do
      verifier = doctor.checks.find { it.name == :verifier }
      expect(verifier).to be_ok
    end

    it "passes the base_controller_name constantize check" do
      base = doctor.checks.find { it.name == :base_controller }
      expect(base).to be_ok
    end

    it "passes the declared-action-has-a-method check (every dummy action maps)" do
      actions = doctor.checks.find { it.name == :actions }
      expect(actions).to be_ok
    end

    it "passes the #id check (dummy classes define #id or are record-backed)" do
      ids = doctor.checks.find { it.name == :ids }
      expect(ids).to be_ok
    end

    it "marks csrf ADVISORY (unknown, not fail) — Phlex-layout apps have no ERB layout" do
      csrf = doctor.checks.find { it.name == :csrf }
      # Never a hard fail — a Phlex-layout app (this gem's audience) would
      # false-flag. It is :ok when a csrf_meta_tags reference is found, else :unknown.
      expect(csrf.status).to be_in(%i[ok unknown])
    end

    it "has no failing checks on a correctly-wired install" do
      expect(doctor.checks.reject(&:ok?).select { it.status == :fail }).to be_empty
    end

    # The whole-app checks scan the Streamable registry, which also holds every
    # Class.new fixture the test suite defines — many deliberately state-backed
    # without #id or with undeclared actions. The doctor validates ONLY
    # constant-resolvable components (a class the endpoint could actually rebuild
    # via safe_constantize), so a faked-`def self.name` fixture never leaks in and
    # red-flags a correctly-wired app.
    it "ignores registry classes whose name does not resolve to the class itself" do
      Class.new(ApplicationComponent) do
        include Phlex::Reactive::Component

        # "Phantom::StateWidget" is not a real constant, so the doctor skips it.
        def self.name = "Phantom::StateWidget"

        reactive_state :n
        # :ghost has no method and the class has no #id — it would fail BOTH
        # component checks if the doctor scanned it.
        action :ghost
        def initialize(n: 0) = (@n = n)
      end

      expect(doctor.checks.select { it.status == :fail }).to be_empty
    end
  end

  describe "the declared-action-has-a-method check (broken fixture)" do
    # A component that declares an action with NO matching public method — the
    # endpoint would 500 on public_send. Defined inline so no second app is booted.
    let(:broken) do
      Class.new(ApplicationComponent) do
        include Phlex::Reactive::Component

        reactive_state :n
        action :ghost # no `def ghost`
        def initialize(n: 0) = (@n = n)
        def id = "broken-action"
      end
    end

    it "flags the missing method" do
      check = doctor.action_check([broken])
      expect(check).not_to be_ok
      expect(check.status).to eq(:fail)
      expect(check.message).to include("ghost")
    end

    it "passes when every declared action has a method" do
      ok = Class.new(ApplicationComponent) do
        include Phlex::Reactive::Component

        reactive_state :n
        action :bump
        def initialize(n: 0) = (@n = n)
        def id = "ok-action"
        def bump = @n += 1
      end
      expect(doctor.action_check([ok])).to be_ok
    end
  end

  describe "the #id override check (broken fixture)" do
    # A state-backed class on the DEFAULT #id still raises NotImplementedError at
    # render — the finding. A record-backed class on the default is FINE (#81).
    let(:state_without_id) do
      Class.new(ApplicationComponent) do
        include Phlex::Reactive::Component

        reactive_state :n
        action :bump
        def initialize(n: 0) = (@n = n)
        def bump = @n += 1
        # NO `def id` — inherits Streamable's default, which raises for state-backed.
      end
    end

    let(:state_with_id) do
      Class.new(ApplicationComponent) do
        include Phlex::Reactive::Component

        reactive_state :n
        def initialize(n: 0) = (@n = n)
        def id = "has-id"
      end
    end

    it "flags a state-backed class that never overrides #id" do
      check = doctor.id_check([state_without_id])
      expect(check).not_to be_ok
      expect(check.status).to eq(:fail)
    end

    it "passes a state-backed class that defines #id" do
      expect(doctor.id_check([state_with_id])).to be_ok
    end

    it "does NOT flag a record-backed class on the default #id (issue #81)" do
      record_backed = Class.new(ApplicationComponent) do
        include Phlex::Reactive::Component

        reactive_record :todo
        def initialize(todo:) = (@todo = todo)
        # no `def id` — record-backed default is FINE, not a finding.
      end
      expect(doctor.id_check([record_backed])).to be_ok
    end
  end

  describe "the advisory authorization check (issue #168)" do
    # ADVISORY only (:unknown, never a hard fail) — the presence-side static
    # heuristic that complements the runtime verify_authorized guard. It flags a
    # non-skipped action whose component defines none of the configured
    # authorization methods in its ancestry AND whose body (Prism-scanned) makes
    # no authorization / mark_authorized! call.

    it "flags a mutating action with no authorization method anywhere and no auth call" do
      unguarded = Class.new(ApplicationComponent) do
        include Phlex::Reactive::Component

        def self.name = "Phlex::Reactive::DoctorSpec::Unguarded"
        reactive_record :todo
        action :destroy
        def initialize(todo:) = (@todo = todo)
        def destroy = @todo.destroy!
      end
      stub_const(unguarded.name, unguarded)

      check = doctor.authorization_check([unguarded])
      expect(check.status).to eq(:unknown)
      expect(check.message).to include("destroy")
    end

    it "does NOT flag an action that calls an authorization method (Prism-detected)" do
      guarded = Class.new(ApplicationComponent) do
        include Phlex::Reactive::Component

        def self.name = "Phlex::Reactive::DoctorSpec::Guarded"
        reactive_record :todo
        action :destroy
        def initialize(todo:) = (@todo = todo)

        def destroy
          authorize! @todo, :destroy?
          @todo.destroy!
        end
      end
      stub_const(guarded.name, guarded)

      expect(doctor.authorization_check([guarded])).to be_ok
    end

    it "does NOT flag an action covered by skip_verify_authorized" do
      skipped = Class.new(ApplicationComponent) do
        include Phlex::Reactive::Component

        def self.name = "Phlex::Reactive::DoctorSpec::Skipped"
        reactive_state :n
        skip_verify_authorized
        action :bump
        def initialize(n: 0) = (@n = n)
        def id = "skipped"
        def bump = @n += 1
      end
      stub_const(skipped.name, skipped)

      expect(doctor.authorization_check([skipped])).to be_ok
    end

    it "does NOT flag a component that defines an authorization method in its ancestry" do
      authz_base = Class.new(ApplicationComponent) do
        include Phlex::Reactive::Component

        def authorize!(*) = true # rubocop:disable Naming/PredicateMethod
      end
      via_helper = Class.new(authz_base) do
        def self.name = "Phlex::Reactive::DoctorSpec::ViaHelper"
        reactive_state :n
        action :bump
        def initialize(n: 0) = (@n = n)
        def id = "via-helper"
        # Authorizes indirectly through a helper the Prism scan can't see, but the
        # component HAS an authorization method defined — advisory stays quiet.
        def bump = do_the_thing

        def do_the_thing
          authorize!
          @n += 1
        end
      end
      stub_const(via_helper.name, via_helper)

      expect(doctor.authorization_check([via_helper])).to be_ok
    end

    it "is included in the full check list as advisory when the dummy runs" do
      Rails.application.eager_load!
      names = doctor.checks.map(&:name)
      expect(names).to include(:authorization)
    end
  end

  # Issue #274: a dormant root is woken by phlex/reactive/early — without that
  # import it never mounts. The doctor counts the components declared dormant
  # and looks for the import in the Stimulus entrypoints. ADVISORY (never a
  # fail): the import may live in a file the doctor doesn't scan.
  describe "the dormant-roots check" do
    let(:dormant) do
      Class.new(ApplicationComponent) do
        include Phlex::Reactive::Component

        def self.name = "SleepyMenu"
        reactive_state :n
        reactive_dormant
        def initialize(n: 0) = (@n = n)
        def id = "sleepy"
      end
    end

    let(:awake) do
      Class.new(ApplicationComponent) do
        include Phlex::Reactive::Component

        reactive_state :n
        def initialize(n: 0) = (@n = n)
        def id = "awake"
      end
    end

    it "is absent when no component is dormant" do
      expect(doctor.dormant_check([awake])).to be_nil
    end

    it "counts the dormant components when phlex/reactive/early is imported" do
      check = doctor.dormant_check([dormant, awake], early: true)

      expect(check).to be_ok
      expect(check.name).to eq(:dormant)
      expect(check.message).to include("1 dormant component (SleepyMenu)")
    end

    it "is advisory, with the import as the fix, when the import is not found" do
      check = doctor.dormant_check([dormant], early: false)

      expect(check.status).to eq(:unknown)
      expect(check.message).to include("SleepyMenu")
      expect(check.fix).to include('import "phlex/reactive/early"')
    end

    it "recognises the import statement, in either quote style and indented" do
      expect(described_class.imports_early_source?(%(import "phlex/reactive/early"\n))).to be(true)
      expect(described_class.imports_early_source?(%(  import 'phlex/reactive/early';\n))).to be(true)
      expect(described_class.imports_early_source?(%(<script type="module">import "phlex/reactive/early"</script>)))
        .to be(true)
    end

    it "does not take a commented-out import for the real thing" do
      expect(described_class.imports_early_source?(%(// import "phlex/reactive/early"\n))).to be(false)
      expect(described_class.imports_early_source?(%(  * import "phlex/reactive/early"\n))).to be(false)
      expect(described_class.imports_early_source?(%(<%# import "phlex/reactive/early" %>\n))).to be(false)
      expect(described_class.imports_early_source?(%(import x from "y" // import "phlex/reactive/early"\n)))
        .to be(false)
    end

    it "does not count an import inside a multi-line or HTML comment" do
      html = %(<!-- <script type="module">import "phlex/reactive/early"</script> -->\n)
      spread = %(<!--\n<script type="module">import "phlex/reactive/early"</script>\n-->\n)
      block = %(/*\nimport "phlex/reactive/early"\n*/\n)

      expect(described_class.imports_early_source?(html)).to be(false)
      expect(described_class.imports_early_source?(spread)).to be(false)
      expect(described_class.imports_early_source?(block)).to be(false)
    end

    it "still counts an import that follows a closed comment or a URL" do
      after_comment = %(/* early capture */ import "phlex/reactive/early"\n)
      after_url = %(const docs = "https://example.com"; import "phlex/reactive/early"\n)

      expect(described_class.imports_early_source?(after_comment)).to be(true)
      expect(described_class.imports_early_source?(after_url)).to be(true)
    end

    it "finds the dummy's dormant component and its early import" do
      Rails.application.eager_load!
      check = doctor.checks.find { it.name == :dormant }

      expect(check).to be_ok
      expect(check.message).to include("DormantPanelComponent")
    end
  end

  # Issue #307: the import may live in any app entry point or inline in a layout
  # or component, and EVERY import map that renders a dormant root needs the pin.
  describe "the early import, wherever it lives" do
    let(:root) { Pathname(Dir.mktmpdir) }
    let(:dormant) do
      Class.new(ApplicationComponent) do
        include Phlex::Reactive::Component

        def self.name = "SleepyMenu"
        reactive_state :n
        reactive_dormant
        def initialize(n: 0) = (@n = n)
        def id = "sleepy"
      end
    end
    let(:import) { %(import "phlex/reactive/early"\n) }

    before { allow(Rails).to receive(:root).and_return(root) }

    after { FileUtils.remove_entry(root) }

    def write(path, content)
      root.join(path).tap { it.dirname.mkpath }.write(content)
    end

    def dormant_message = doctor.dormant_check([dormant]).message

    it "finds an import in a Phlex layout and names the file" do
      write("app/views/layouts/base.rb", "script(type: 'module') { raw(safe('#{import.strip}')) }\n")

      expect(doctor.send(:imports_early?)).to eq("app/views/layouts/base.rb")
      check = doctor.dormant_check([dormant])
      expect(check).to be_ok
      expect(check.message).to include("phlex/reactive/early is imported (app/views/layouts/base.rb)")
    end

    it "finds an import in an ERB layout and names the file" do
      write("app/views/layouts/landing.html.erb", %(<script type="module">#{import}</script>\n))

      expect(doctor.dormant_check([dormant]).message).to include("(app/views/layouts/landing.html.erb)")
    end

    it "finds an import in a component" do
      write("app/components/shell.rb", "raw(safe('#{import.strip}'))\n")

      expect(doctor.send(:imports_early?)).to eq("app/components/shell.rb")
    end

    it "finds an import in a per-page entry file and names it" do
      write("app/javascript/pages/landing.js", import)

      expect(dormant_message).to include("(app/javascript/pages/landing.js)")
    end

    it "ignores vendored JavaScript" do
      write("app/javascript/vendor/thing.js", import)

      expect(doctor.send(:imports_early?)).to be(false).or be_nil
      expect(doctor.dormant_check([dormant])).not_to be_ok
    end

    it "ignores a commented-out import in a layout" do
      write("app/views/layouts/base.rb", "# #{import}")
      write("app/views/layouts/old.html.erb", %(<%# #{import.strip} %>\n))

      expect(doctor.dormant_check([dormant])).not_to be_ok
    end

    it "leaves the output unchanged for an import in a Stimulus registration file" do
      write("app/javascript/application.js", import)

      check = doctor.dormant_check([dormant])
      expect(check.message).to eq("1 dormant component (SleepyMenu); phlex/reactive/early is imported")
    end

    describe "#early_pin_check" do
      def map_with(*pins)
        Struct.new(:packages).new(pins.to_h { [it, { path: "#{it}.js" }] })
      end

      let(:pinned) { map_with("phlex/reactive/early") }
      let(:bare) { map_with("other") }

      after { Phlex::Reactive.importmaps = nil }

      it "is absent when nothing is dormant" do
        Phlex::Reactive.importmaps = -> { { "landing" => bare } }

        expect(doctor.early_pin_check([])).to be_empty
      end

      it "reports nothing when every map pins the module" do
        Phlex::Reactive.importmaps = -> { { "app" => pinned, "landing" => pinned } }

        expect(doctor.early_pin_check([dormant])).to be_empty
      end

      it "names the map lacking the pin, with the fix" do
        Phlex::Reactive.importmaps = -> { { "app" => pinned, "landing" => bare } }

        checks = doctor.early_pin_check([dormant])
        expect(checks.size).to eq(1)
        expect(checks.first.status).to eq(:unknown)
        expect(checks.first.name).to eq(:early_pin)
        expect(checks.first.message).to include('import map "landing"', "phlex/reactive/early")
        expect(checks.first.fix).to include('pin "phlex/reactive/early"')
      end

      it "reports the map by name in the doctor's output" do
        Phlex::Reactive.importmaps = -> { { "app" => pinned, "landing" => bare } }
        allow(doctor).to receive(:registered_components).and_return([dormant]) # rubocop:disable RSpec/SubjectStub

        expect(doctor.report).to include('? import map "landing" does not pin phlex/reactive/early')
      end

      it "checks Rails.application.importmap when no registry is configured" do
        allow(Rails.application).to receive(:importmap).and_return(bare)

        checks = doctor.early_pin_check([dormant])
        expect(checks.map(&:message)).to contain_exactly(a_string_including('import map "application"'))
      end

      it "adds the configured maps to the default one" do
        allow(Rails.application).to receive(:importmap).and_return(bare)
        Phlex::Reactive.importmaps = -> { { "landing" => bare } }

        names = doctor.early_pin_check([dormant]).map(&:message)
        expect(names).to contain_exactly(a_string_including('"application"'), a_string_including('"landing"'))
      end

      it "survives a registry that raises" do
        Phlex::Reactive.importmaps = -> { raise "boom" }

        expect { doctor.early_pin_check([dormant]) }.not_to raise_error
      end

      it "passes quietly for the default map when it pins the module" do
        allow(Rails.application).to receive(:importmap).and_return(pinned)

        expect(doctor.early_pin_check([dormant])).to be_empty
      end
    end
  end

  describe "output rendering" do
    before { Rails.application.eager_load! }

    it "renders stable plain text (no ANSI color codes) with ✓/✗/? glyphs" do
      output = doctor.report
      expect(output).not_to match(/\e\[[0-9;]*m/) # no ANSI escapes
      expect(output).to match(/[✓✗?]/)
    end

    it "prints the fix line for each failing check" do
      broken = Class.new(ApplicationComponent) do
        include Phlex::Reactive::Component

        reactive_state :n
        action :ghost
        def initialize(n: 0) = (@n = n)
        def id = "x"
      end
      check = doctor.action_check([broken])
      output = doctor.render_check(check)
      expect(output).to include("✗")
      expect(output).to include(check.fix)
    end
  end
end
