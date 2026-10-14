# frozen_string_literal: true

# Issue #398: a permission tree whose leaves all post as ONE perms[] array.
# reactive_select_all("perms[]") is the root header; reactive_select_all(
# "perms[]", under: "library") and under: "library.books" are branch headers.
# A leaf names its nearest parent with data-reactive-group. Headers have no
# name, so they never post, and reactive_count counts leaves only. A nested
# reactive root's leaf in the "library" path is never flipped by this root.
class NestedSelectionComponent < ApplicationComponent
  include Phlex::Reactive::ClientBindings

  def initialize(result: nil)
    @result = result
  end

  def view_template
    p(data: { testid: "result" }) { @result.to_s }
    div(id: "perms-root", **reactive_root) do
      form(id: "perms", action: "/nested_selection", method: "post") do
        group_header("all", reactive_select_all("perms[]", data: { testid: "all" }))
        ul do
          li do
            group_header("Library", reactive_select_all("perms[]", under: "library", data: { testid: "library" }))
            ul do
              li { leaf("notes", "library") }
              li do
                group_header("Books", reactive_select_all("perms[]", under: "library.books", data: { testid: "books" }))
                ul do
                  li { leaf("view", "library.books") }
                  li { leaf("edit", "library.books") }
                end
              end
            end
          end
          li { leaf("billing", "billing") }
        end
        p do
          plain "Selected: "
          span(**reactive_count("perms[]", data: { testid: "count" })) { "0" }
        end
        button(type: "submit", data: { testid: "save" }) { "Save" }
      end
      div(data: { controller: "reactive" }) do
        input(type: "checkbox", name: "perms[]", value: "nested", data: { testid: "nested", reactive_group: "library" })
      end
    end
  end

  private

  def group_header(text, attrs)
    label do
      input(type: "checkbox", **attrs)
      plain " #{text}"
    end
  end

  def leaf(value, group)
    label do
      input(type: "checkbox", name: "perms[]", value:, data: { testid: value, reactive_group: group })
      plain " #{value}"
    end
  end
end
