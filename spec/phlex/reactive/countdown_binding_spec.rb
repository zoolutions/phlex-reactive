# frozen_string_literal: true

require "spec_helper"
require "phlex"

# Issue #400: reactive_countdown — the client counts a server deadline down
# (unpadded minutes, a colon, padded seconds), and at zero hides waiting:,
# shows done: and fires reactive:countdown-done once. The wire carries the
# deadline, the format and two selectors; the server renders the initial text
# and visibility itself.
RSpec.describe Phlex::Reactive::Component::CountdownBinding do
  let(:klass) do
    Class.new(Phlex::HTML) do
      include Phlex::Reactive::ClientBindings

      def self.name = "OtpTimer"

      def view_template
        div(**reactive_root) do
          span(**reactive_countdown(until: "2026-10-14T12:02:00Z", waiting: "#wait", done: "#done")) { "2:00" }
          div(id: "wait") { "Waiting" }
          div(id: "done", hidden: true) { "Finished" }
        end
      end
    end
  end

  let(:view) { klass.new }
  let(:deadline) { "2026-10-14T12:02:00Z" }

  def wire(attrs) = JSON.parse(attrs[:data][:reactive_countdown])

  it "carries the deadline and the format" do
    expect(wire(view.reactive_countdown(until: deadline))).to eq("until" => deadline, "format" => "ms")
  end

  it "carries waiting: and done: as selectors" do
    expect(wire(view.reactive_countdown(until: deadline, waiting: "#wait", done: "#done")))
      .to eq("until" => deadline, "format" => "ms", "waiting" => "#wait", "done" => "#done")
  end

  it "accepts an offset and fractional seconds" do
    ["2026-10-14T14:02:00+02:00", "2026-10-14T12:02:00.250Z", "2026-10-14T07:02:00-05:00"].each do
      expect(wire(view.reactive_countdown(until: it))["until"]).to eq(it)
    end
  end

  it "takes a Time (or TimeWithZone) and writes its ISO8601 form" do
    time = Time.utc(2026, 10, 14, 12, 2, 0)
    zoned = time.in_time_zone("Europe/Stockholm")
    expect(zoned.to_s).to include("+0200")
    [time, zoned].each do
      expect(wire(view.reactive_countdown(until: it))["until"]).to eq("2026-10-14T12:02:00Z")
    end
  end

  it "deep-merges extra attrs (mix), keeping the binding" do
    attrs = view.reactive_countdown(until: deadline, class: "tabular-nums", data: { testid: "clock" })
    expect(attrs[:class]).to eq("tabular-nums")
    expect(attrs[:data]).to include(testid: "clock")
    expect(attrs[:data]).to have_key(:reactive_countdown)
  end

  it "renders the attribute, leaving the text and visibility to the server's render" do
    html = view.call
    expect(html).to include("data-reactive-countdown=")
    expect(html).to include(">2:00</span>")
    expect(html).to include('<div id="done" hidden>Finished</div>')
  end

  describe "validation (loud, at render)" do
    it "raises on a format: other than :ms" do
      [:hms, "ms", nil, :seconds].each do
        format = it
        expect { view.reactive_countdown(until: deadline, format:) }
          .to raise_error(ArgumentError, /format: must be :ms/), "expected #{format.inspect} to raise"
      end
    end

    it "raises on an until: that is not an ISO8601 date-time with a zone" do
      ["soon", "", "2026-10-14", "2026-10-14T12:02:00", "2026-13-14T12:02:00Z", "14/10/2026 12:02", nil, 1_760_000_000,
       Date.new(2026, 10, 14)].each do
        value = it
        expect { view.reactive_countdown(until: value) }
          .to raise_error(ArgumentError, /until: must be an ISO8601/), "expected #{value.inspect} to raise"
      end
    end

    it "raises on a waiting: or done: that is not a non-empty selector String" do
      expect { view.reactive_countdown(until: deadline, waiting: :wait) }.to raise_error(ArgumentError, /waiting:/)
      expect { view.reactive_countdown(until: deadline, done: " ") }.to raise_error(ArgumentError, /done:/)
    end

    it "raises on the @root sentinel (it would hide the whole root)" do
      expect { view.reactive_countdown(until: deadline, done: "@root") }.to raise_error(ArgumentError, /@root/)
    end
  end
end
