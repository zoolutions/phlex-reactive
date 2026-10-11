# frozen_string_literal: true

module Phlex
  module Reactive
    module Component
      # Editable text (issue #351): a contenteditable element as a first-class,
      # PLAIN-TEXT field — an inline title, a card label, a note edited where
      # it is shown.
      #
      #   h3(**reactive_editable(:title, placeholder: "Untitled")) { @card.title }
      #   p(**reactive_editable(:summary, multiline: true)) { @card.summary }
      #   h3(**mix(reactive_editable(:title), on(:rename, event: "input", debounce: 300))) { @card.title }
      #
      # The element is the caller's; this renders its attributes. The client
      # then gives it what an input gets:
      #   * collect — its text, line breaks as "\n" (a single-line field folds
      #     them to spaces), posted under the (scope-aware) param name;
      #   * a morph while it is focused keeps its text and caret (attributes
      #     still morph); unfocused, the server's text wins;
      #   * paste and drop insert plain text; Enter runs on_enter: (a
      #     single-line field swallows it by default); Escape reverts;
      #   * reactive_dirty and reactive_persist treat it like an input.
      #
      # Plain text only — a rich editor (Lexxy, Trix) is collected by `.value`.
      # The placeholder is CSS's to draw:
      #   [data-reactive-placeholder]:empty::before { content: attr(data-reactive-placeholder) }
      module Editable
        # on_enter: a Phlex::Reactive::JS chain (run on Enter, root-scoped like
        # on_client) or :submit (request-submit the form the field is in).
        # on_escape: :revert (restore the last server-rendered text and blur)
        # or nil. spellcheck: false renders spellcheck="false".
        def reactive_editable(name, multiline: false, placeholder: nil, on_enter: nil, on_escape: :revert,
                              spellcheck: true, **attrs)
          raise ArgumentError, "reactive_editable needs a param name (e.g. reactive_editable(:title))" if name.to_s.empty?

          data = { reactive_editable: multiline ? "multi" : "single" }
          data[:reactive_editable_enter] = editable_enter(on_enter) unless on_enter.nil?
          data[:reactive_editable_escape] = editable_escape(on_escape) unless on_escape.nil?
          aria = { multiline: multiline.to_s }
          if placeholder
            aria[:placeholder] = placeholder
            data[:reactive_placeholder] = placeholder
          end
          binding = { name: scoped_field_name(name), contenteditable: "plaintext-only", role: "textbox", aria:, data: }
          binding[:spellcheck] = "false" unless spellcheck
          # Named by `reactive_dirty only:` → its own trackDirty descriptor, as
          # reactive_field does (issue #184).
          data[:action] = "input->reactive#trackDirty" if field_dirty_tracked?(name)
          # An explicit scalar (name:, role:, …) REPLACES the binding's, as
          # reactive_field's escape hatch does — mix would space-join two
          # strings. data:/aria: hashes deep-merge.
          mix(binding.reject { |key, _| attrs.key?(key) && !attrs[key].is_a?(Hash) }, attrs)
        end

        private

        def editable_enter(on_enter)
          return "submit" if on_enter == :submit

          unless on_enter.is_a?(Phlex::Reactive::JS)
            raise ArgumentError,
              "reactive_editable on_enter: takes a Phlex::Reactive::JS chain (e.g. js.focus(\"#next\")) " \
              "or :submit, got #{on_enter.inspect}"
          end
          raise ArgumentError, "reactive_editable on_enter: got a JS chain with no ops — a dead Enter" if on_enter.empty?

          on_enter.ops.to_json
        end

        def editable_escape(on_escape)
          return "revert" if on_escape == :revert

          raise ArgumentError, "reactive_editable on_escape: takes :revert or nil, got #{on_escape.inspect}"
        end
      end
    end
  end
end
