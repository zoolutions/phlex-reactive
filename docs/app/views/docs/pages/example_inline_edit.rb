# frozen_string_literal: true

module Views
  module Docs
    module Pages
      class ExampleInlineEdit < DocsUI::Page
        title 'Example: inline edit + dirty tracking'
        eyebrow 'Examples'
        description 'Build click-to-edit fields in reactive Phlex for Rails: Enter saves, Escape cancels, focus survives the morph, an Unsaved badge tracks dirty state'

        def lead
          'Click-to-edit that replaces a Stimulus controller plus three routes: ' \
            'Enter saves, Escape cancels, focus survives the morph. Plus dirty-field ' \
            'tracking — an “Unsaved” badge and a leave-guard — with ZERO state shipped ' \
            'to the client.'
        end

        def content
          inline_edit
          the_component
          dirty_tracking
          dirty_component
          notes
        end

        private

        def inline_edit
          DocsUI::Section('Try it — click to edit') do
            md <<~MD
              Click the value below to edit it, then **Enter** (or Save) to persist
              and **Escape** (or Cancel) to back out. The mode (`editing`) rides in
              the signed token alongside the record's GlobalID, so the show ↔ edit
              flip is one reactive round trip — no client state, no bespoke JS.
            MD
            render Views::Examples::LiveExample.new(
              component: InlineEditComponent.new(record: inline_demo_todo, attribute: :title),
              filename: 'app/components/inline_edit_component.rb'
            )
          end
        end

        def the_component
          DocsUI::Section('How it works') do
            md <<~MD
              `reactive_record :record` signs the record's GlobalID;
              `reactive_state :attribute, :editing` signs which column and the mode.
              Every action re-finds the record server-side and re-renders. `save`
              lives on the **Save button**, not the input — so focusing the field
              doesn't dispatch save and collapse edit mode. `Escape` is bound with
              `event: "click keydown.esc"`, Stimulus's native keyboard filter.
            MD
          end
        end

        def dirty_tracking
          DocsUI::Section('Try it — dirty tracking') do
            md <<~MD
              Edit the field: an **“Unsaved”** badge appears on the first keystroke
              and the browser warns before you navigate away. Save and it clears —
              all with **no state shipped to the client**. The browser already holds
              the last server-rendered value in `input.defaultValue`, so
              *dirty = current ≠ default*; the badge is revealed purely by CSS while
              the root carries `data-reactive-dirty`.
            MD
            render Views::Examples::LiveExample.new(
              component: DirtyFormComponent.new(todo: dirty_demo_todo),
              filename: 'app/components/dirty_form_component.rb'
            )
          end
        end

        def dirty_component
          DocsUI::Section('How dirty tracking works') do
            md <<~MD
              `reactive_dirty warn_unsaved: true`, declared once at the class
              level, mixes `input->reactive#trackDirty` onto the root and arms a
              navigate-away guard gated on the live dirty count — every field
              under the root tracks by default. On `save` the action morphs, so
              the reply re-renders the field with the NEW value as its fresh
              `defaultValue` — the post-morph re-scan finds it clean and the badge
              clears without a full-page reload.
            MD
          end
        end

        def notes
          DocsUI::Section('Notes') do
            DocsUI::Callout(:tip) do
              md <<~MD
                Both widgets bind to their own demo record, so editing them here
                won't touch the [live todo list](/docs/example-todo-list). In your
                app the same `InlineEditComponent` works against any record +
                attribute — `render InlineEditComponent.new(record: @user,
                attribute: :name)`.
              MD
            end
            DocsUI::Callout(:note) do
              md <<~MD
                To edit the text where it is shown, with no input to swap in, see
                [Editable text](/docs/editable-text): `reactive_editable` makes the
                displayed element itself the field.
              MD
            end
          end
        end

        # Dedicated demo records, found-or-created so repeated page renders reuse
        # one row instead of piling up duplicates. Kept separate from the todo-list
        # rows so editing here is isolated.
        def inline_demo_todo
          Todo.find_or_create_by!(title: 'Click me to rename inline')
        end

        def dirty_demo_todo
          Todo.find_or_create_by!(title: 'Edit me to see the Unsaved badge')
        end
      end
    end
  end
end
