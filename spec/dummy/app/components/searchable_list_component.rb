# frozen_string_literal: true

# A client-only helper (issue #410): type to narrow a list of options. It has
# its own tokenless root for the filter and declares no action. The caller
# yields the options, which may carry the triggers of the server component
# this list is rendered in.
class SearchableListComponent < ApplicationComponent
  include Phlex::Reactive::ClientBindings

  def initialize(name:)
    @name = name
  end

  def reactive_values = { q: "" }

  def view_template(&)
    div(**mix(
      reactive_root(id: "searchable-#{@name}", data: { testid: "searchable-#{@name}" }),
      reactive_filter(:q, option: "[data-option]")
    )) do
      input(name: "q", form: "searchable-#{@name}-unowned", data: { testid: "search-#{@name}" })
      yield
    end
  end
end
