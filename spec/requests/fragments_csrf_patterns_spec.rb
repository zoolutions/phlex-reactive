# frozen_string_literal: true

require "rails_helper"

# The fragment endpoint's CSRF-name patterns (issue #277) are compiled once per
# forgery-protection field name and kept in per-Ractor state
# (Phlex::Reactive::Store) rather than a Concurrent::Map constant
# (zoolutions/phlex-reactive#364).
RSpec.describe Phlex::Reactive::FragmentsController, "CSRF token patterns" do
  def markup_pattern(token_name)
    controller = described_class.new
    allow(controller).to receive(:request_forgery_protection_token).and_return(token_name)
    controller.send(:csrf_token_markup)
  end

  it "compiles one pattern per field name and reuses it" do
    first = markup_pattern("my_token")

    expect(markup_pattern("my_token")).to be(first)
    expect(markup_pattern("other_token")).not_to be(first)
  end

  it "matches the well-known names and the controller's own field, in any quoting" do
    pattern = markup_pattern("my_token")

    expect(pattern).to match('<input name="authenticity_token">')
      .and match("<meta name='csrf-token'>")
      .and match("<input name=my_token>")
    expect(pattern).not_to match('<input name="my_token_extra">')
  end

  it "keeps the patterns out of constants" do
    expect(described_class.const_defined?(:CSRF_TOKEN_PATTERNS, false)).to be(false)
  end
end
