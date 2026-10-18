# frozen_string_literal: true

# Issue #442: a pickable list bound ONCE. The list carries a single on_client
# record with within: "[role=option]"; each row carries only its data-*. A pick
# (a click anywhere in a row, or Enter on the row the arrow keys highlight)
# writes the row's value into the hidden field, its label into the summary,
# marks it selected and tells the page — every value read off the row that
# was picked (:trigger), none baked into the chain. The "Recent" heading
# inside the list is not a row: a click there runs nothing.
class PickListComponent < Phlex::HTML
  include Phlex::Reactive::ClientBindings

  ITEMS = [
    { id: 1, value: 'north', label: 'North', hint: 'Cold and quiet' },
    { id: 2, value: 'south', label: 'South', hint: 'Warm all year' },
    { id: 3, value: 'east', label: 'East', hint: 'First to see the sun' },
    { id: 4, value: 'west', label: 'West', hint: 'Long evenings' }
  ].freeze

  def view_template
    div(**reactive_root(id: 'pick-list', class: 'flex flex-col gap-3 max-w-sm')) do
      input(id: 'pl-value', type: 'hidden', name: 'region')
      input(id: 'pl-query', type: 'search', placeholder: 'Arrow keys, then Enter', autocomplete: 'off',
            class: 'input input-bordered input-sm', **reactive_listnav('[role=option]'))
      ul(id: 'pl-menu', role: 'listbox', class: 'menu bg-base-200 rounded-box w-full',
         **on_client(:click, pick, within: '[role=option]')) do
        li(class: 'menu-title') { 'Recent' }
        ITEMS.each { |item| row(item) }
      end
      p(class: 'text-sm') do
        plain 'Picked: '
        strong(id: 'pl-label') { 'nothing yet' }
        plain ' — value '
        code(id: 'pl-shown') { '""' }
      end
    end
  end

  private

  # Each row: its own data and markup, no op chain.
  def row(item)
    li do
      button(type: 'button', role: 'option', id: "pl-#{item[:id]}",
             class: 'flex flex-col items-start aria-selected:menu-active data-reactive-highlighted:bg-base-300',
             data: { id: item[:id], value: item[:value], label: item[:label] }) do
        span(class: 'font-medium') { item[:label] }
        span(class: 'text-xs opacity-70') { item[:hint] }
      end
    end
  end

  # The ONE chain every row shares: each value is read off the picked row.
  def pick
    js.set_value('#pl-value', from: :trigger, attr: 'data-value')
      .text('#pl-label', from: :trigger, attr: 'data-label')
      .text('#pl-shown', from: :trigger, attr: 'data-value')
      .remove_attr('[role=option]', 'aria-selected')
      .set_attr(:trigger, 'aria-selected', 'true')
      .dispatch('region:picked', detail_from: { id: 'data-id', value: 'data-value' })
  end
end
