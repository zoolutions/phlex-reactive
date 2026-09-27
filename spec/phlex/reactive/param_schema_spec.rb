# frozen_string_literal: true

require "spec_helper"

# Issue #109: the coerce family extracted out of ActionsController into a
# standalone, compiled-once ParamSchema. Two contracts this spec pins:
#
#   1. COMPILE — declaration-time validation. Every type symbol (recursively:
#      nested hash + array-of-hash element types) is checked against the
#      registry; an unknown symbol raises Phlex::Reactive::UnknownParamType (an
#      ArgumentError subclass) at compile, not a silent to_s at request time.
#   2. COERCE — the drop-don't-fabricate contract, byte-for-byte with the old
#      controller: built-ins keep their exact semantics (:integer "abc" → 0,
#      not DROP; :file duck-type DROP; the array/hash DROP rules), and the
#      verbose_errors collector records path-prefixed [path, reason] entries.
RSpec.describe Phlex::Reactive::ParamSchema do
  # The internal DROP sentinel is private; assert on the RESULT of coerce (a
  # dropped key is simply absent from the coerced hash) rather than the sentinel.
  def coerce(schema, params, collector = nil)
    described_class.compile(schema).coerce(params, collector)
  end

  describe ".compile — declaration-time validation" do
    it "accepts the shipped built-in scalars" do
      expect { described_class.compile({ a: :string, b: :integer, c: :float, d: :boolean, e: :file }) }
        .not_to raise_error
    end

    it "raises UnknownParamType for a typo'd type symbol" do
      expect { described_class.compile({ count: :interger }) }
        .to raise_error(Phlex::Reactive::UnknownParamType, /interger/)
    end

    it "raises UnknownParamType as an ArgumentError subclass (not a NameError)" do
      expect(Phlex::Reactive::UnknownParamType.ancestors).to include(ArgumentError)
      expect { described_class.compile({ x: :nope }) }.to raise_error(ArgumentError)
    end

    it "validates a NESTED hash element type recursively" do
      expect { described_class.compile({ invoice: { date: :string, bad: :notatype } }) }
        .to raise_error(Phlex::Reactive::UnknownParamType, /notatype/)
    end

    it "validates an ARRAY element type" do
      expect { described_class.compile({ ids: [:whoops] }) }
        .to raise_error(Phlex::Reactive::UnknownParamType, /whoops/)
    end

    it "validates an ARRAY-OF-HASH element type recursively" do
      schema = { items: [{ id: :integer, qty: :flooat }] }
      expect { described_class.compile(schema) }
        .to raise_error(Phlex::Reactive::UnknownParamType, /flooat/)
    end

    it "names the offending key and the whole registry is not mutated by a failed compile" do
      expect { described_class.compile({ x: :bogus }) }
        .to raise_error(Phlex::Reactive::UnknownParamType)
      # a subsequent VALID compile still works (no half-registration state)
      expect { described_class.compile({ x: :string }) }.not_to raise_error
    end
  end

  describe "#coerce — shipped built-ins, byte-for-byte" do
    it ":integer casts via to_i (a non-numeric string becomes 0, NOT dropped)" do
      expect(coerce({ n: :integer }, { "n" => "abc" })).to eq(n: 0)
      expect(coerce({ n: :integer }, { "n" => "42" })).to eq(n: 42)
    end

    it ":float casts via to_f" do
      expect(coerce({ n: :float }, { "n" => "2.5" })).to eq(n: 2.5)
      expect(coerce({ n: :float }, { "n" => "x" })).to eq(n: 0.0)
    end

    it ":boolean casts via ActiveModel and KEEPS an unrecognized value as nil (not DROP)" do
      expect(coerce({ b: :boolean }, { "b" => "1" })).to eq(b: true)
      expect(coerce({ b: :boolean }, { "b" => "0" })).to eq(b: false)
      # ActiveModel casts a blank string to nil (its FALSE_VALUES include ""),
      # and that nil is KEPT (the key is present) — it does NOT DROP. This is the
      # shipped controller's behavior; a boolean never drops.
      expect(coerce({ b: :boolean }, { "b" => "" })).to eq(b: nil)
    end

    it ":string is the default cast (to_s)" do
      expect(coerce({ s: :string }, { "s" => 5 })).to eq(s: "5")
    end

    it "drops undeclared keys (no mass assignment)" do
      expect(coerce({ a: :string }, { "a" => "x", "admin" => "true" })).to eq(a: "x")
    end

    it "drops a declared key that is absent from the payload (keyword default applies)" do
      expect(coerce({ a: :string, b: :integer }, { "a" => "x" })).to eq(a: "x")
    end
  end

  describe "#coerce — :file duck-type DROP" do
    let(:upload) do
      Class.new do
        def original_filename = "x.png"
        def read(*) = "bytes"
      end.new
    end

    it "passes an uploaded file through untouched" do
      expect(coerce({ f: :file }, { "f" => upload })).to eq(f: upload)
    end

    it "drops a non-file value sent to a :file param (keyword default applies)" do
      expect(coerce({ f: :file }, { "f" => "not-a-file" })).to eq({})
    end
  end

  describe "#coerce — array rules (DROP-don't-fabricate)" do
    it "coerces a real array element-wise" do
      expect(coerce({ ids: [:integer] }, { "ids" => %w[1 2 3] })).to eq(ids: [1, 2, 3])
    end

    it "accepts a Rails index hash in index order" do
      expect(coerce({ ids: [:integer] }, { "ids" => { "0" => "10", "1" => "11" } })).to eq(ids: [10, 11])
    end

    it "drops a present-but-non-array scalar rather than fabricating [scalar]" do
      # coercing a stray scalar to [] would read as an explicit 'clear everything'
      expect(coerce({ ids: [:integer] }, { "ids" => "5" })).to eq({})
    end

    it "keeps a genuinely empty array as []" do
      expect(coerce({ ids: [:integer] }, { "ids" => [] })).to eq(ids: [])
    end

    it "drops an array whose every element drops (a [:file] of non-files)" do
      expect(coerce({ pages: [:file] }, { "pages" => %w[a b] })).to eq({})
    end
  end

  describe "#coerce — nested hash + bracket expansion" do
    it "recurses into a nested hash schema, dropping undeclared nested keys" do
      schema = { invoice: { date: :string, status: :string } }
      params = { "invoice" => { "date" => "2026-01-02", "status" => "open", "secret" => "x" } }
      expect(coerce(schema, params)).to eq(invoice: { date: "2026-01-02", status: "open" })
    end

    it "expands flat bracketed keys (Rails Form(model:)) before matching" do
      schema = { invoice: { date: :string, status: :string } }
      params = { "invoice[date]" => "2026-01-02", "invoice[status]" => "open" }
      expect(coerce(schema, params)).to eq(invoice: { date: "2026-01-02", status: "open" })
    end

    it "deep-merges a bracket key with a sibling pre-nested object" do
      schema = { invoice: { date: :string, status: :string } }
      params = { "invoice[date]" => "2026-01-02", "invoice" => { "status" => "open" } }
      expect(coerce(schema, params)).to eq(invoice: { date: "2026-01-02", status: "open" })
    end

    it "drops a malformed (non-hash) nested param rather than fabricating {}" do
      # The hash analog of the malformed-array rule: a nested `invoice: null` or a
      # stray scalar must NOT become an empty {} (which update!(invoice:) would
      # read as an explicit no-op object). Drop it so the keyword default applies.
      schema = { invoice: { date: :string, status: :string } }
      expect(coerce(schema, { "invoice" => nil })).to eq({})
      expect(coerce(schema, { "invoice" => "oops" })).to eq({})
    end

    it "keeps a genuinely empty nested hash as {} (explicit empty object)" do
      schema = { invoice: { date: :string, status: :string } }
      expect(coerce(schema, { "invoice" => {} })).to eq(invoice: {})
    end

    it "records a malformed nested hash as uncoercible for the collector" do
      dropped = []
      coerce({ invoice: { date: :string } }, { "invoice" => nil }, dropped)
      expect(dropped).to include(["invoice", :uncoercible])
    end

    it "coerces the array-of-hash Rails bracket form (the bench payload shape)" do
      schema = {
        date: :string,
        bank_account_ids: [:integer],
        invoice_items_attributes: [{ id: :integer, quantity: :float, price: :float, _destroy: :boolean }]
      }
      params = {
        "date" => "2026-01-02",
        "bank_account_ids[]" => %w[1 2 3],
        "invoice_items_attributes[0][id]" => "10",
        "invoice_items_attributes[0][quantity]" => "2.5",
        "invoice_items_attributes[0][price]" => "9.99",
        "invoice_items_attributes[0][_destroy]" => "false"
      }
      expect(coerce(schema, params)).to eq(
        date: "2026-01-02",
        bank_account_ids: [1, 2, 3],
        invoice_items_attributes: [{ id: 10, quantity: 2.5, price: 9.99, _destroy: false }]
      )
    end
  end

  describe "#coerce — a schema-less action drops everything" do
    it "returns {} for an empty schema regardless of payload" do
      expect(coerce({}, { "anything" => "x" })).to eq({})
    end
  end

  describe "new built-in: :date" do
    it "parses an ISO8601 date" do
      expect(coerce({ d: :date }, { "d" => "2026-01-02" })).to eq(d: Date.new(2026, 1, 2))
    end

    it "DROPs an unparseable date (keyword default applies)" do
      expect(coerce({ d: :date }, { "d" => "not-a-date" })).to eq({})
    end

    it "DROPs a blank string" do
      expect(coerce({ d: :date }, { "d" => "" })).to eq({})
    end
  end

  describe "new built-in: :datetime" do
    it "parses an ISO8601 datetime" do
      expect(coerce({ t: :datetime }, { "t" => "2026-01-02T10:30:00Z" }))
        .to eq(t: DateTime.iso8601("2026-01-02T10:30:00Z"))
    end

    it "DROPs an unparseable datetime" do
      expect(coerce({ t: :datetime }, { "t" => "garbage" })).to eq({})
    end
  end

  describe "new built-in: :decimal" do
    it "parses a decimal via BigDecimal" do
      expect(coerce({ amount: :decimal }, { "amount" => "9.99" })).to eq(amount: BigDecimal("9.99"))
    end

    it "DROPs a non-numeric string (BigDecimal ArgumentError)" do
      expect(coerce({ amount: :decimal }, { "amount" => "abc" })).to eq({})
    end
  end

  describe "app-registered custom param types" do
    around do
      # These specs register+unregister a temporary type; keep the registry
      # unfrozen for the duration and restore it afterward.
      Phlex::Reactive.reset_param_types! if Phlex::Reactive.respond_to?(:reset_param_types!)
      it.run
    ensure
      Phlex::Reactive.reset_param_types! if Phlex::Reactive.respond_to?(:reset_param_types!)
    end

    it "casts through a registered callable" do
      Phlex::Reactive.param_type(:shout) {  it.to_s.upcase }
      expect(coerce({ s: :shout }, { "s" => "hi" })).to eq(s: "HI")
    end

    it "DROPs when the callable returns the DROP sentinel" do
      Phlex::Reactive.param_type(:money) {  /\A\d+\z/.match?(it.to_s) ? Integer(it) : Phlex::Reactive::ParamSchema::DROP }
      expect(coerce({ m: :money }, { "m" => "500" })).to eq(m: 500)
      expect(coerce({ m: :money }, { "m" => "abc" })).to eq({})
    end

    it "compiles a schema referencing a registered type without raising" do
      Phlex::Reactive.param_type(:slug) { it.to_s.downcase.tr(" ", "-") }
      expect { described_class.compile({ s: :slug }) }.not_to raise_error
    end
  end

  describe "registry is frozen after boot" do
    around do
      was_frozen = Phlex::Reactive.param_types_frozen?
      Phlex::Reactive.reset_param_types!
      it.run
    ensure
      Phlex::Reactive.reset_param_types!
      Phlex::Reactive.freeze_param_types! if was_frozen
    end

    it "rejects registration after freeze_param_types!" do
      Phlex::Reactive.freeze_param_types!
      expect { Phlex::Reactive.param_type(:late) { |v| v } }
        .to raise_error(Phlex::Reactive::Error, /frozen|boot|initializer/i)
    end
  end

  describe "verbose_errors collector plumbing" do
    it "records an undeclared top-level key with its reason" do
      dropped = []
      coerce({ a: :string }, { "a" => "x", "admin" => "true" }, dropped)
      expect(dropped).to include(["admin", :undeclared])
    end

    it "records an undeclared NESTED key with its full bracketed path" do
      dropped = []
      schema = { invoice_items_attributes: [{ id: :integer }] }
      coerce(schema, { "invoice_items_attributes" => [{ "id" => "1", "secret" => "x" }] }, dropped)
      expect(dropped).to include(["invoice_items_attributes[0][secret]", :undeclared])
    end

    it "records a declared key whose value could not be coerced as uncoercible" do
      dropped = []
      coerce({ ids: [:integer] }, { "ids" => "5" }, dropped)
      expect(dropped).to include(["ids", :uncoercible])
    end

    it "records a dropped ARRAY ELEMENT with its bracketed index" do
      dropped = []
      coerce({ pages: [:file] }, { "pages" => ["not-a-file"] }, dropped)
      expect(dropped).to include(["pages[0]", :uncoercible])
    end

    it "does zero collector work when the collector is nil (production path)" do
      # nil collector must never raise and must produce the same coerced result
      expect(coerce({ a: :string }, { "a" => "x", "admin" => "true" }, nil)).to eq(a: "x")
    end
  end

  # Issue #258: the endpoint fills an announced empty group only where the
  # DECLARATION names an array type, so it asks the compiled schema rather than
  # reading the incoming params. Reading the declaration is schema logic (#109),
  # and here its rules are reachable from a unit spec.
  describe "#array_param — what may be announced empty" do
    def array_param(schema, name) = described_class.compile(schema).array_param(name)

    it "answers the declared key for an array type" do
      expect(array_param({ tags: [:string] }, "tags")).to eq(:tags)
    end

    it "answers the key as WRITTEN for a string-keyed declaration" do
      # compile keeps whichever form the author used, and the endpoint writes
      # the key it gets back, so the form has to survive the lookup.
      expect(array_param({ "tags" => [:string] }, "tags")).to eq("tags")
    end

    it "is nil for a scalar type" do
      expect(array_param({ tags: :string }, "tags")).to be_nil
    end

    it "is nil for a nested hash, whatever it declares inside" do
      expect(array_param({ project: { tags: [:string] } }, "project")).to be_nil
    end

    it "is nil for an undeclared name" do
      expect(array_param({ tags: [:string] }, "other")).to be_nil
    end

    it "is nil for a key that is neither a String nor a Symbol" do
      # `compile` validates types, never keys, so `{ 0 => [:string] }` is legal —
      # but coerce_hash raises on `0.to_sym` the moment that key is PRESENT, and
      # an announcement is what would make it present. Answering nil keeps a
      # request that returns 200 and fills nothing from becoming a 500.
      expect(array_param({ 0 => [:string] }, "0")).to be_nil
    end
  end
end
