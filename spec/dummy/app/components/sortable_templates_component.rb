# frozen_string_literal: true

# Issue #350: a source list on a client-only root (no token). Its rows are
# copied into any sortable of the "tasks" group, never moved.
class SortableTemplatesComponent < ApplicationComponent
  include Phlex::Reactive::ClientBindings

  def view_template
    div(**reactive_root(id: "sortable-templates")) do
      ul(**mix(reactive_sortable_source(group: "tasks", name: "templates"), data: { testid: "templates" })) do
        %w[bug chore].each { template_row(it) }
      end
    end
  end

  private

  def template_row(key)
    li(**mix(reactive_sortable_item(key), tabindex: -1, data: { testid: "template-#{key}" })) { key }
  end
end
