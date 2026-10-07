# frozen_string_literal: true

require "rails_helper"

# The Response value object is unit-testable as a plain return value — no
# controller/request boot. (to_stream_* and flash_builder render through the
# configured renderer, so rails_helper provides the view context.)
RSpec.describe Phlex::Reactive::Response do
  let(:counter) { CounterComponent.new(count: 0) }
  let(:todo) { Todo.create!(title: "t", done: false) }
  let(:item) { TodoItemComponent.new(todo:) }

  it "replace renders a self-targeted replace stream and keeps render_self" do
    response = counter.reply.replace
    expect(response.render_self?).to be(true)
    expect(response.redirect?).to be(false)
    expect(response.streams.size).to eq(1)
    expect(response.streams.first).to include('action="replace"')
    expect(response.streams.first).to include('target="counter"')
  end

  it "replace + flash composes two streams" do
    response = counter.reply.replace.flash(:notice, "hi")
    expect(response.streams.size).to eq(2)
    expect(response.streams.last).to include('action="append"')
    expect(response.streams.last).to include('target="flash"')
    expect(response.streams.last).to include("hi")
  end

  it "remove opts out of render_self and emits a remove stream" do
    response = item.reply.remove
    expect(response.render_self?).to be(false)
    expect(response.streams.first).to include('action="remove"')
    expect(response.streams.first).to include(%(target="#{ActionView::RecordIdentifier.dom_id(todo)}"))
  end

  it "redirect carries the url, opts out of render_self, and has no streams" do
    response = counter.reply.redirect("/x")
    expect(response.redirect?).to be(true)
    expect(response.redirect_url).to eq("/x")
    expect(response.render_self?).to be(false)
    expect(response.streams).to be_empty
  end

  it "is immutable — stream/flash return new instances" do
    base = counter.reply.replace
    expect(base.stream("<turbo-stream></turbo-stream>")).not_to equal(base)
    expect(base.streams.size).to eq(1) # original unchanged
    expect(base).to be_frozen
  end

  # Issue #25: re-render self + a companion element/component without dropping to
  # raw turbo_stream_builder.
  describe "also (companion elements)" do
    it "also appends an update stream for an arbitrary target id" do
      response = counter.reply.replace.also("page_heading" => "New name")

      expect(response.streams.size).to eq(2)
      expect(response.render_self?).to be(true)
      expect(response.streams.last).to include('action="update"')
      expect(response.streams.last).to include('target="page_heading"')
      expect(response.streams.last).to include("New name")
    end

    it "also renders a Phlex component (auto-escaped) into the companion stream" do
      probe = Class.new(Phlex::HTML) do
        def self.name = "HeadingProbe"
        def view_template = strong { "Bold heading" }
      end
      response = counter.reply.with.also("page_heading" => probe.new)

      expect(response.streams.first).to include("<strong>Bold heading</strong>")
    end

    it "also HTML-escapes a plain string (a model value is safe)" do
      # Turbo's TagBuilder escapes a plain String passed to html:, so a model
      # value can't inject markup. (Pass an html_safe string or a Phlex
      # component to emit intentional raw HTML.)
      response = counter.reply.with.also("page_heading" => "<em>Live</em>")

      expect(response.streams.first).to include("&lt;em&gt;Live&lt;/em&gt;")
      expect(response.streams.first).not_to include("<em>Live</em>")
    end

    it "also emits an html_safe string as raw markup" do
      response = counter.reply.with.also("page_heading" => "<em>Live</em>".html_safe)

      expect(response.streams.first).to include("<em>Live</em>")
    end

    it "also renders another Streamable component, targeting its own id" do
      response = counter.reply.replace.also(item)

      expect(response.streams.size).to eq(2)
      expect(response.streams.last).to include('action="replace"')
      expect(response.streams.last).to include(%(target="#{ActionView::RecordIdentifier.dom_id(todo)}"))
    end

    it "is immutable — also returns new instances and keeps render_self" do
      base = counter.reply.replace
      extended = base.also("h" => "x")
      expect(extended).not_to equal(base)
      expect(base.streams.size).to eq(1) # original unchanged
      expect(extended.render_self?).to be(true)
    end

    it "chains alongside flash and stream" do
      response = counter.reply.replace
        .also("heading" => "n")
        .flash(:notice, "saved")

      expect(response.streams.size).to eq(3)
    end
  end

  # Issue #28: morph re-renders self in place via Idiomorph (method="morph"),
  # preserving the focused input + caret. reply.morph is the explicit
  # builder; reply.replace(morph: true) is the opt-in flag; also gains a
  # morph: flag for companion components.
  describe "morph (issue #28)" do
    it "morph renders a self-targeted morphing replace and keeps render_self" do
      response = counter.reply.morph
      expect(response.render_self?).to be(true)
      expect(response.redirect?).to be(false)
      expect(response.streams.size).to eq(1)
      expect(response.streams.first).to include('action="replace"')
      expect(response.streams.first).to include('method="morph"')
      expect(response.streams.first).to include('target="counter"')
    end

    it "replace(morph: true) emits the morph attribute" do
      response = counter.reply.replace(morph: true)
      expect(response.streams.first).to include('method="morph"')
    end

    it "replace defaults to a plain swap (no morph attr) — back-compat" do
      response = counter.reply.replace
      expect(response.streams.first).not_to include("method=")
    end

    it "morph composes with flash (token still refreshes via the morph)" do
      response = counter.reply.morph.flash(:notice, "saved")
      expect(response.streams.size).to eq(2)
      expect(response.streams.first).to include('method="morph"')
      expect(response.streams.last).to include('action="append"')
    end

    it "also(component, morph: true) morphs the companion component" do
      response = counter.reply.morph.also(item, morph: true)
      expect(response.streams.size).to eq(2)
      expect(response.streams.last).to include('method="morph"')
      expect(response.streams.last).to include(%(target="#{ActionView::RecordIdentifier.dom_id(todo)}"))
    end

    it "also defaults to a plain replace (no morph attr)" do
      response = counter.reply.replace.also(item)
      expect(response.streams.last).not_to include("method=")
    end

    # Issue #113: reply.update gains the same morph: flag replace already has.
    it "update(morph: true) emits a morphing update" do
      response = counter.reply.update(morph: true)
      expect(response.streams.first).to include('action="update"')
      expect(response.streams.first).to include('method="morph"')
    end

    it "update defaults to a plain update (no morph attr) — back-compat" do
      response = counter.reply.update
      expect(response.streams.first).to include('action="update"')
      expect(response.streams.first).not_to include("method=")
    end
  end

  # Issue #77: the flash level must reach the wire. String content gets a
  # level-carrying wrapper (class + data attribute); Phlex component content
  # renders VERBATIM (byte-identical to before — the caller owns the markup);
  # Phlex::Reactive.flash_component swaps the default wrapper for the app's own
  # flash component (string content only).
  describe "flash levels (issue #77)" do
    it ":error and :notice produce different streams" do
      error = counter.reply.with.flash(:error, "boom").streams.first
      notice = counter.reply.with.flash(:notice, "saved").streams.first

      expect(error.to_s.gsub("boom", "MSG")).not_to eq(notice.to_s.gsub("saved", "MSG"))
      expect(error).to include('class="reactive-flash reactive-flash--error"')
      expect(error).to include('data-reactive-flash-level="error"')
      expect(notice).to include('class="reactive-flash reactive-flash--notice"')
      expect(notice).to include('data-reactive-flash-level="notice"')
    end

    it "keeps HTML-escaping plain string content (injection contract unchanged)" do
      stream = counter.reply.with.flash(:notice, "<em>x</em> & y").streams.first

      expect(stream).to include("&lt;em&gt;x&lt;/em&gt; &amp; y")
      expect(stream).not_to include("<em>x</em>")
      expect(stream).to include('class="reactive-flash reactive-flash--notice"')
    end

    it "passes an html_safe string verbatim INSIDE the wrapper (intentional raw HTML)" do
      stream = counter.reply.with.flash(:notice, "<em>x</em>".html_safe).streams.first

      expect(stream).to include('data-reactive-flash-level="notice"')
      expect(stream).to include("<em>x</em>")
    end

    it "HTML-escapes the level (it lands in a class name and a data attribute)" do
      stream = counter.reply.with.flash(%(err"or><script>), "x").streams.first

      expect(stream).not_to include('err"or><script>')
      expect(stream).to include("err&quot;or&gt;&lt;script&gt;")
    end

    it "renders Phlex component content VERBATIM — byte-identical to the raw builder append, no wrapper" do
      klass = Class.new(Phlex::HTML) do
        def self.name = "FlashPassthroughProbe"
        def view_template = span { "rendered flash" }
      end

      via_flash = counter.reply.with.flash(:error, klass.new).streams.first
      raw = Phlex::Reactive.stream_builder.append("flash", html: Phlex::Reactive.render(klass.new))

      expect(via_flash.to_s).to eq(raw.to_s)
      expect(via_flash).not_to include("reactive-flash")
    end

    describe "Phlex::Reactive.flash_component" do
      let(:flash_component) do
        Class.new(Phlex::HTML) do
          def self.name = "AppFlashProbe"

          def initialize(level:, content:)
            @level = level
            @content = content
          end

          def view_template = div(class: "toast toast--#{@level}") { @content }
        end
      end

      around do
        Phlex::Reactive.flash_component = ->(level, content) { flash_component.new(level:, content:) }
        it.run
      ensure
        Phlex::Reactive.flash_component = nil
      end

      it "renders string content through the configured component (level + content)" do
        stream = counter.reply.with.flash(:error, "Save failed").streams.first

        expect(stream).to include('class="toast toast--error"')
        expect(stream).to include("Save failed")
        expect(stream).not_to include("reactive-flash")
      end

      it "component content still bypasses flash_component (renders verbatim)" do
        klass = Class.new(Phlex::HTML) do
          def self.name = "CustomFlashCard"
          def view_template = span { "custom card" }
        end

        stream = counter.reply.with.flash(:error, klass.new).streams.first

        expect(stream).to include("<span>custom card</span>")
        expect(stream).not_to include("toast")
      end
    end
  end

  it "flash accepts a Phlex component, rendered through the configured renderer" do
    klass = Class.new(Phlex::HTML) do
      # ActionView's render logger needs a name
      def self.name = "FlashAlertProbe"
      def view_template = span { "rendered flash" }
    end
    response = counter.reply.with.flash(:error, klass.new)
    expect(response.streams.first).to include("rendered flash")
  end

  # Issue #30: reply.streams(*strings) emits EXACTLY the caller's streams plus
  # a token-only refresh — render_self is false (no full-self replace), so
  # partial/per-field updates don't clobber live inputs, yet the signed token
  # still rolls forward via the tiny reactive:token stream the endpoint
  # appends from the bound component.
  describe "streams (issue #30 — partial update, token-only refresh)" do
    it "opts out of render_self (no forced full-self replace)" do
      response = counter.reply.streams("<turbo-stream></turbo-stream>")
      expect(response.render_self?).to be(false)
    end

    it "carries exactly the caller's streams (does not prepend a self replace)" do
      response = counter.reply.streams(item.to_stream_update)
      expect(response.streams.size).to eq(1)
      expect(response.streams.first).to include('action="update"')
      expect(response.streams.first).to include(%(target="#{ActionView::RecordIdentifier.dom_id(todo)}"))
    end

    it "remembers the bound component so the endpoint can refresh its token" do
      response = counter.reply.streams("<turbo-stream></turbo-stream>")
      expect(response.token_component).to eq(counter)
    end

    it "is NOT redirect and is immutable" do
      response = counter.reply.streams
      expect(response.redirect?).to be(false)
      expect(response).to be_frozen
    end

    it "chains flash/stream while staying render_self false and keeping the component" do
      response = counter.reply.streams(item.to_stream_update).flash(:notice, "saved")
      expect(response.streams.size).to eq(2)
      expect(response.streams.last).to include('action="append"')
      expect(response.render_self?).to be(false)
      expect(response.token_component).to eq(counter)
    end
  end

  # Issue #97: Response#js(ops) chains a `reactive:js` op stream — server-pushed
  # client DOM ops (focus, dispatch, class/attr toggles) — onto any reply. The
  # ops attr is HTML-escaped (a raw interpolation would be an injection vector),
  # emitted via the immutable stream() plumbing, and — crucially — LAST, so a
  # focus op sees the post-render DOM (the endpoint guarantees ordering; here we
  # assert the chain shape + escaping).
  describe "js (issue #97 — server-pushed client DOM ops)" do
    let(:ops) { CounterComponent.new(count: 0).js.focus("[name=next]").dispatch("app:saved") }

    it "chains a reactive:js op stream onto a replace, immutably" do
      base = counter.reply.replace
      response = base.js(ops)

      expect(response).not_to equal(base)
      expect(base.streams.size).to eq(1) # original unchanged
      expect(response.streams.size).to eq(2)
      expect(response.streams.last).to include('action="reactive:js"')
      expect(response.render_self?).to be(true)
    end

    it "emits the op stream LAST (after the render stream)" do
      response = counter.reply.morph.js(ops)

      expect(response.streams.first).to include('action="replace"') # the morph render
      expect(response.streams.last).to include('action="reactive:js"')
    end

    it "carries the ops as an HTML-escaped data-reactive-ops attribute" do
      stream = counter.reply.with.js(ops).streams.first

      # The wire format is the JSON op list, HTML-escaped (quotes → &quot;).
      expect(stream).to include("data-reactive-ops=")
      expect(stream).to include("&quot;focus&quot;")
      expect(stream).to include("&quot;app:saved&quot;")
      # The raw double-quotes of the JSON must NOT appear unescaped inside the attr.
      expect(stream).not_to include('data-reactive-ops="[["focus"')
    end

    it "escapes a hostile op payload (no attribute break-out)" do
      hostile = CounterComponent.new(count: 0).js.dispatch(%(x"><script>alert(1)</script>))
      stream = counter.reply.with.js(hostile).streams.first

      expect(stream).not_to include('"><script>')
      expect(stream).to include("&quot;")
    end

    it "defaults the stream target to the bound component's id (self-scoped ops)" do
      # replace/morph/update bind the component, so js ops scope to its root by
      # default — reply.morph.js(js.focus("@root")) focuses the morphed root.
      stream = counter.reply.replace.js(ops).streams.last
      expect(stream).to include('target="counter"')
    end

    it "accepts an explicit target: override" do
      stream = counter.reply.with.js(ops, target: "sidebar").streams.first
      expect(stream).to include('target="sidebar"')
    end

    it "omits target entirely for a subject-free reply with no explicit target (document-scoped)" do
      stream = counter.reply.with.js(ops).streams.first
      expect(stream).not_to include("target=")
    end

    it "accepts a raw op array as well as a JS chain" do
      stream = counter.reply.with.js([["focus", { "to" => "@root" }]]).streams.first
      expect(stream).to include("&quot;focus&quot;")
    end

    # Issue #226: submit is actor-only like focus — refused in broadcasts, but
    # the actor's own reply may commit a form it just morphed.
    it "allows a submit op (actor-scoped, mirroring focus)" do
      stream = counter.reply.with.js(CounterComponent.new(count: 0).js.submit).streams.first
      expect(stream).to include("&quot;submit&quot;")
    end

    # Issue #228: paste_into is actor-only the same way — refused in broadcasts,
    # but the actor's own reply may arm a clipboard paste it just rendered.
    it "allows a paste_into op (actor-scoped, mirroring focus/submit)" do
      stream = counter.reply.with.js(CounterComponent.new(count: 0).js.paste_into("#code")).streams.first
      expect(stream).to include("&quot;paste_into&quot;")
    end

    # Issue #342: check_group is actor-only too — the actor's own reply may
    # clear the selection it just acted on.
    it "allows a check_group op (actor-scoped, mirroring focus/submit)" do
      stream = counter.reply.with.js(CounterComponent.new(count: 0).js.check_group("ids[]", false)).streams.first
      expect(stream).to include("&quot;check_group&quot;")
    end

    it "enforces the attr allowlist on a raw op array (escape hatch can't bypass it)" do
      hostile = [["set_attr", { "to" => "#x", "name" => "onclick", "value" => "alert(1)" }]]
      expect { counter.reply.with.js(hostile) }.to raise_error(ArgumentError, /onclick/)
    end

    it "rejects an empty op chain (a dead reactive:js stream is a mistake)" do
      empty = CounterComponent.new(count: 0).js
      expect { counter.reply.with.js(empty) }.to raise_error(ArgumentError, /no ops/)
    end

    it "chains alongside flash (ops stay after the render, flash after that)" do
      response = counter.reply.replace.flash(:notice, "saved").js(ops)
      expect(response.streams.size).to eq(3)
      expect(response.streams.last).to include('action="reactive:js"')
    end

    # Issue #237: the op stream carries the verbose gate so the client can warn
    # on zero-target resolution even for document-scoped ops (no controller root
    # to read the flag from). Restore the lazy default by removing the ivar.
    describe "the verbose stamp (issue #237)" do
      around do
        it.run
      ensure
        if Phlex::Reactive.instance_variable_defined?(:@verbose_errors)
          Phlex::Reactive.remove_instance_variable(:@verbose_errors)
        end
      end

      it "stamps data-reactive-verbose on the op stream when verbose_errors is on" do
        Phlex::Reactive.verbose_errors = true
        stream = counter.reply.with.js(ops).streams.first
        expect(stream).to include('data-reactive-verbose="true"')
      end

      it "omits the stamp when verbose_errors is off (production wire unchanged)" do
        Phlex::Reactive.verbose_errors = false
        stream = counter.reply.with.js(ops).streams.first
        expect(stream).not_to include("data-reactive-verbose")
      end
    end
  end

  # Issue #100: dismiss_after — a flash that self-removes after N ms. The wrapper
  # carries data-reactive-dismiss-after="<ms>"; a document-level client handler
  # removes the container after the timeout (works for reply AND broadcast
  # flashes, since it isn't tied to any Stimulus controller). Off by default —
  # no attribute unless the caller opts in.
  describe "dismiss_after: (issue #100)" do
    it "wraps a string flash with data-reactive-dismiss-after when set" do
      stream = counter.reply.with.flash(:error, "boom", dismiss_after: 4000).streams.first

      expect(stream).to include('data-reactive-dismiss-after="4000"')
      expect(stream).to include('class="reactive-flash reactive-flash--error"')
      expect(stream).to include("boom")
    end

    it "omits the attribute entirely when dismiss_after is not given (default)" do
      stream = counter.reply.with.flash(:error, "boom").streams.first

      expect(stream).not_to include("data-reactive-dismiss-after")
    end

    it "coerces the ms to an integer string (a float/String can't inject an attribute)" do
      stream = counter.reply.with.flash(:notice, "hi", dismiss_after: "4000\"><script>").streams.first

      expect(stream).to include('data-reactive-dismiss-after="4000"')
      expect(stream).not_to include("<script>")
    end

    it "still HTML-escapes the content inside a dismissing wrapper (injection contract)" do
      stream = counter.reply.with.flash(:notice, "<em>x</em> & y", dismiss_after: 3000).streams.first

      expect(stream).to include("&lt;em&gt;x&lt;/em&gt; &amp; y")
      expect(stream).not_to include("<em>x</em>")
    end

    it "applies dismiss_after to flash_component content too (wraps the rendered component)" do
      klass = Class.new(Phlex::HTML) do
        def self.name = "DismissFlashProbe"

        def initialize(level:, content:)
          @level = level
          @content = content
        end

        def view_template = div(class: "toast") { @content }
      end
      allow(Phlex::Reactive).to receive(:flash_component).and_return(->(level, content) { klass.new(level:, content:) })

      stream = counter.reply.with.flash(:error, "boom", dismiss_after: 2000).streams.first

      expect(stream).to include('data-reactive-dismiss-after="2000"')
      expect(stream).to include("toast")
    end

    it "does NOT wrap verbatim Phlex component content (the caller owns the markup)" do
      klass = Class.new(Phlex::HTML) do
        def self.name = "VerbatimDismissProbe"
        def view_template = span { "flash" }
      end

      stream = counter.reply.with.flash(:error, klass.new, dismiss_after: 2000).streams.first

      # Component content renders verbatim — no built-in wrapper, so no place for
      # the gem to hang dismiss_after. Documented limitation: dismiss_after wraps
      # only STRING content; a component owns its own lifecycle.
      expect(stream).not_to include("data-reactive-dismiss-after")
    end
  end
end
