# frozen_string_literal: true

# reactive_filter's match: and fold: (issue #425) over a list of accented city
# names. Each option's haystack is its own text; the filter matches at the
# start of a word and folds diacritics, so "n" keeps Nantes and New York (not
# every name with an n in it) and "zur" finds Zürich. Client-only: no action,
# no token.
class CityFilterComponent < ApplicationComponent
  include Phlex::Reactive::ClientBindings

  CITIES = ["Århus", "Berlin", "Nantes", "New York", "Santander", "Zürich"].freeze

  def view_template
    div(**mix(
      reactive_root(id: "city-filter", data: { testid: "city-filter" }),
      reactive_filter(:q, empty: "#city-filter-none", match: :word_start, fold: true)
    )) do
      input(name: "q", type: "search", autocomplete: "off", data: { testid: "city-query" })
      ul do
        CITIES.each { |city| li(role: "option", data: { testid: "city-#{city.parameterize}" }) { city } }
      end
      p(id: "city-filter-none", hidden: true, data: { testid: "city-none" }) { "No match" }
    end
  end
end
