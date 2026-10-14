# frozen_string_literal: true

require "spec_helper"
require "phlex"

# Issues #395/#394/#396: a show/enable binding that names ANOTHER field — same:,
# and later after:/clear: — is checked against the fields the render actually
# produced. An unknown name raises at render (after the template ran, so a
# field rendered below the binding counts), never silently in the browser.
RSpec.describe Phlex::Reactive::Component::FieldReferences do
  def build(scope: nil, &template)
    Class.new(Phlex::HTML) do
      include Phlex::Reactive::ClientBindings

      def self.name = "FieldRefThing"

      reactive_scope scope if scope
      define_method(:view_template, &template)
    end
  end

  it "renders when same: names a field the render produced (even below the binding)" do
    klass = build do
      div(**reactive_root) do
        button(**reactive_enable(if: { confirm: { same: :email } })) { "Save" }
        input(name: "email")
        input(name: "confirm")
      end
    end

    expect(klass.new.call).to include('data-reactive-enable="')
  end

  it "raises at render when same: names no rendered field" do
    klass = build do
      div(**reactive_root) do
        input(name: "confirm")
        p(**reactive_show(unless: { confirm: { same: :emial } })) { "differ" }
      end
    end

    expect { klass.new.call }.to raise_error(ArgumentError, /same: :emial|"emial"/)
  end

  it "resolves a bare same: name through reactive_scope" do
    ok = build(scope: :user) do
      div(**reactive_root) do
        input(name: "user[email]")
        input(name: "user[confirm]")
        p(**reactive_show(if: { confirm: { same: :email } })) { "ok" }
      end
    end
    bare = build(scope: :user) do
      div(**reactive_root) do
        input(name: "email")
        p(**reactive_show(if: { confirm: { same: :email } })) { "ok" }
      end
    end

    expect { ok.new.call }.not_to raise_error
    expect { bare.new.call }.to raise_error(ArgumentError, /user\[email\]/)
  end

  it "counts a field a nested component renders" do
    child = Class.new(Phlex::HTML) do
      def view_template = input(name: "email")
    end
    klass = build do
      div(**reactive_root) do
        p(**reactive_show(if: { confirm: { same: :email } })) { "ok" }
        render child.new
      end
    end

    expect { klass.new.call }.not_to raise_error
  end

  it "raises at render when after: waits for a field the render never produced (issue #396)" do
    klass = build do
      div(**reactive_root) { p(**reactive_show(unless: { code: { digits: 10 } }, after: :blur)) { "bad" } }
    end

    expect { klass.new.call }.to raise_error(ArgumentError, /after: :code names no field/)
  end

  it "does not check a render that flushes (the scan would miss fields above the flush)" do
    klass = build do
      div(**reactive_root) do
        input(name: "email")
        flush
        input(name: "confirm")
        p(**reactive_show(if: { confirm: { same: :email } })) { "ok" }
      end
    end

    expect { klass.new.call }.not_to raise_error
  end

  it "does not check a helper called outside a render (no buffer to read)" do
    klass = build { div }

    expect { klass.new.send(:reactive_show, if: { a: { same: :nowhere } }) }.not_to raise_error
  end

  it "leaves a binding without a field reference unchecked" do
    klass = build do
      div(**reactive_root) { p(**reactive_show(if: { never_rendered: "x" })) { "ok" } }
    end

    expect { klass.new.call }.not_to raise_error
  end
end
