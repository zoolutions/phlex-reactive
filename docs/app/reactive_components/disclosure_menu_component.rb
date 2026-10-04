# frozen_string_literal: true

# Issue #271: an accessible disclosure menu (the WAI-ARIA menu-button pattern)
# with NO actions and NO custom JS — every behavior is a declared on_client op:
#
# * the trigger keeps aria-expanded honest: a two-value toggle_attr on click,
#   expanded: on ArrowDown (open + focus the first item);
# * the menu roves focus among role=menuitem with Arrow/Home/End
#   (reactive_listnav(focus: true));
# * the root closes the menu on an outside click AND on Escape (focus back to
#   the trigger) — two on_client bindings on one element, composed by mix.
class DisclosureMenuComponent < Phlex::HTML
  include Phlex::Reactive::Component

  ITEMS = %w[Rename Duplicate Archive].freeze

  def id = 'disclosure-menu'

  def view_template
    close = js.hide('#dm-menu', expanded: '#dm-trigger')

    div(**mix(reactive_root,
              on_client(:click, close, outside: true),
              on_client('keydown.esc', close.focus('#dm-trigger')),
              class: 'flex flex-col gap-3')) do
      div(class: 'relative w-fit') do
        trigger
        menu
      end
      p(class: 'text-sm') do
        plain 'Picked: '
        span(id: 'dm-status', class: 'font-semibold') { 'nothing' }
      end
    end
  end

  private

  def trigger
    # aria_expanded is the STRING "false": Phlex drops a boolean false entirely.
    button(id: 'dm-trigger', aria_haspopup: 'menu', aria_expanded: 'false', aria_controls: 'dm-menu',
           **mix(on_client(:click, js.toggle('#dm-menu').toggle_attr('#dm-trigger', 'aria-expanded', 'true', 'false')),
                 on_client('keydown.down', js.show('#dm-menu', expanded: '#dm-trigger').focus_first('#dm-menu')),
                 class: 'btn btn-sm')) { 'Actions ▾' }
  end

  def menu
    ul(id: 'dm-menu', role: 'menu', hidden: true, aria_labelledby: 'dm-trigger',
       **mix(reactive_listnav(focus: true),
             class: 'menu absolute z-10 mt-1 w-40 rounded-box border border-base-300 bg-base-100 p-1 shadow')) do
      ITEMS.each do |label|
        li(role: 'none') do
          button(role: 'menuitem', tabindex: '-1',
                 **on_client(:click, js.hide('#dm-menu', expanded: '#dm-trigger').text('#dm-status', label))) { label }
        end
      end
    end
  end
end
