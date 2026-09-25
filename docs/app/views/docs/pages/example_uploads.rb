# frozen_string_literal: true

module Views
  module Docs
    module Pages
      # A code-first walkthrough of file/multipart params and custom param types.
      # Deliberately NOT a live demo — a public upload endpoint is a storage/abuse
      # surface, and the docs app carries no ActiveStorage. The component shown is
      # the dummy DocumentUploadComponent (#34/#39) reproduced inline as reference
      # code (the docs are self-contained: the gem's spec/dummy is gone at deploy).
      class ExampleUploads < DocsUI::Page
        title 'File uploads & custom types'
        eyebrow 'Examples'
        description 'Accept file uploads in a reactive Phlex action with :file and [:file] coercion over multipart FormData, plus nested params and custom Rails param types'

        def lead
          'Accept a file in a reactive action — attach a document, receipt, or ' \
            'image to a record without dropping out to a bespoke controller — and ' \
            'register your own coerced param type. A code-first walkthrough; there ' \
            'is no live upload demo (a public upload endpoint is a storage/abuse surface).'
        end

        def content
          the_component
          how_multipart
          nested_and_meta
          custom_types
          checklist
        end

        private

        def the_component
          DocsUI::Section('A component that accepts a file') do
            md <<~MD
              Declare `:file` (or `[:file]` for multiple) in the action's param
              schema. When the reactive root holds a populated `<input type="file">`,
              the client sends the action as multipart `FormData` instead of JSON;
              the endpoint coerces the declared `:file` param to the
              `ActionDispatch::Http::UploadedFile` and passes it through untouched.
              The action attaches it — the rest of the reactive flow (token
              threading, re-render/morph) is identical.

              ```ruby
              class DocumentUploadComponent < ApplicationComponent
                include Phlex::Reactive::Streamable
                include Phlex::Reactive::Component

                reactive_record :document

                # Single-file path (has_one_attached). A caption rides alongside as a
                # scalar field to prove multipart carries scalar params + the file.
                action :upload, params: { file: :file, caption: :string }
                # Multiple-file path (has_many_attached): [:file] coerces an array.
                action :upload_pages, params: { pages: [:file] }

                def initialize(document:) = @document = document

                def id = dom_id(@document)

                def upload(file: nil, caption: nil)
                  @document.file.attach(file) if file
                  @document.update!(title: caption) if caption.present?
                end

                def upload_pages(pages: nil)
                  @document.pages.attach(pages) if pages.present?
                end

                def view_template
                  div(**mix(reactive_attrs, id:)) do
                    span { @document.title }
                    form(**on(:upload, event: "submit")) do
                      input(type: "file", name: "file")
                      input(name: "caption")
                      button(type: "submit") { "Upload" }
                    end
                  end
                end
              end
              ```
            MD
          end
        end

        def how_multipart
          DocsUI::Section('How the multipart path works') do
            md <<~MD
              Only the request **encoding** changes when a file is present — the
              action never sees the difference:

              - When a populated `<input type="file">` is in the root, the client
                switches from a JSON body to multipart `FormData`.
              - `token` and `act` ride as fields; scalar params (`caption`) ride as
                fields; the file(s) are appended.
              - A **cleared checkbox group** can't be written as an empty array in
                a form body, so its name goes into `empty_groups[]` and the
                endpoint sets the declared array param to `[]`. The action sees
                the same as over JSON.
              - The endpoint coerces `:file` to the uploaded file, passed through
                untouched. A **non-file** value sent to a `:file` param is dropped
                (the keyword default applies — never a fabricated file), the same
                drop-don't-fabricate contract as every built-in type.
              - `[:file]` coerces an **array** of uploads for a `has_many_attached`
                target.

              ```ruby
              action :upload,       params: { file: :file, caption: :string }
              action :upload_pages, params: { pages: [:file] }
              ```
            MD
          end
        end

        def nested_and_meta
          DocsUI::Section('A file alongside nested params (#39)') do
            md <<~'MD'
              A `:file` param can sit next to an explicit **nested-hash** param. On
              the multipart path, nested and array params are **bracket-expanded**
              into `params[key][sub]` / `params[key][index]` fields — the same
              Rails-form shape a JSON body produces — so a JSON body and a multipart
              body coerce **identically**. The nested `meta` used to be dropped on
              the multipart path (issue #39); it now survives next to the file.
              Bracketed field **names** expand the same way: an input named
              `blog_post[summary]` riding next to `blog_post[image]` is sent as
              `params[blog_post][summary]` — never the Rack-unparseable
              `params[blog_post[summary]]` that corrupted scalars and silently
              dropped files (issue #231):

              ```ruby
              action :upload_with_meta,
                params: { file: :file, meta: { tag: :string, year: :integer } }

              def upload_with_meta(file: nil, meta: nil)
                @document.file.attach(file) if file
                @document.update!(title: "#{meta[:tag]} #{meta[:year]}") if meta
              end
              ```

              The schema mirrors the field **names**, not the conceptual params — a
              flat `{ tag: :string }` against `meta[tag]` inputs would match nothing
              and drop silently. When in doubt, read a field's real `name` attribute
              and shape the schema to it.
            MD
          end
        end

        def custom_types
          DocsUI::Section('Registering a custom param type (:money)') do
            md <<~'MD'
              File params are one built-in type; you can register your own. In an
              initializer, `Phlex::Reactive.param_type` takes a block that receives
              the raw client value and returns the coerced value — or
              `Phlex::Reactive::ParamSchema::DROP` to reject it, so the keyword
              default applies (the same drop-don't-fabricate contract):

              ```ruby
              # config/initializers/phlex_reactive.rb
              Phlex::Reactive.param_type(:money) do |value|
                if /\A\d+(\.\d{1,2})?\z/.match?(value.to_s)
                  BigDecimal(value)
                else
                  Phlex::Reactive::ParamSchema::DROP
                end
              end

              # then, in any component:
              action :charge, params: { amount: :money }
              def charge(amount:) = @invoice.charge!(amount)   # a BigDecimal, or unset
              ```
            MD

            DocsUI::Callout(:warning, title: 'Register during boot only') do
              md <<~MD
                The type registry is **frozen after initialization**, so a runtime
                `param_type` call raises. A schema that references a registered type
                is validated at declaration like any built-in — a typo raises
                `Phlex::Reactive::UnknownParamType` at class load, not at click time.
              MD
            end
          end
        end

        def checklist
          DocsUI::Section('What this example proves') do
            md <<~MD
              - `:file` and `[:file]` accept single and multiple uploads in a
                reactive action, coerced to `ActionDispatch::Http::UploadedFile`.
              - Scalar params (`caption`) ride alongside the file through multipart.
              - A nested-hash param (`meta`) survives next to the file (#39).
              - A custom `param_type(:money)` coerces or drops, and is validated at
                declaration.

              For the reference detail, see
              [Actions & events](/docs/actions-events) (the `on(...)` API and the
              full param-types table) and the file-params note in
              [Security](/docs/security).
            MD
          end
        end
      end
    end
  end
end
