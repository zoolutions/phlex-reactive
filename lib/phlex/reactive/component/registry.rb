# frozen_string_literal: true

module Phlex
  module Reactive
    module Component
      # ONE inheritance semantic for every Component class-level registry
      # (issue #115). Before this, the five registries hand-rolled two DIVERGENT
      # patterns: reactive_record_key walked the superclass LIVE on every read,
      # while reactive_actions/reactive_state_keys/reactive_collections/
      # reactive_computes snapshot-dup'd the parent on FIRST access — so a
      # parent declaring an action after a subclass had been read was visible
      # via record-key semantics but silently invisible via action semantics.
      #
      # The unified semantic is the live one: **resolve through the superclass
      # at read time**, memoized per class against a process-wide generation
      # counter bumped on any registry write. Declarations happen at class-load
      # (boot, dev reload), so post-boot reads are pure memo hits; a late
      # declaration anywhere simply invalidates the memos lazily via the
      # generation compare on next read.
      #
      # === The hot-path contract (issue #115 invariant, performance rule) ===
      # The generation check gates registry RESOLUTION only. The identity-side
      # memos read on EVERY reactive_token render — @reactive_record_ivar and
      # @reactive_state_ivars (Component::Identity) — stay bare defined?/||=
      # fast paths with NO per-read comparison. They are invalidated HERE, at
      # write time: bump! sweeps them off the writing class and all its
      # descendants (a declaration is rare and class-load-shaped; a render is
      # not). That write-time sweep is also what fixes the pre-#115 split-brain
      # where a parent's late reactive_record left a subclass's memoized ivar
      # stale against the live reactive_record_key.
      #
      # Storage layout (all on the component class itself, so a Zeitwerk
      # reload's fresh class object starts clean and nothing global retains a
      # reference to app classes):
      #   * @reactive_own_*              — the class's OWN declarations
      #   * @reactive_registry_cache     — kind => resolved value
      #   * @reactive_registry_generation — the generation the cache was built at
      #
      # Resolved values are fresh copies per class (merge/+), matching the
      # pre-#115 mutability surface: mutating a returned collection never
      # reaches an ancestor. Direct mutation of a returned registry is
      # unsupported either way — it bypasses the generation bump, so the next
      # declaration anywhere discards it. Declare through the DSL.
      module Registry
        # The class ivar carrying each registry's OWN declarations. A frozen
        # lookup table (not :"@reactive_own_#{kind}") so no read or write
        # allocates an intermediate string.
        OWN_IVARS = {
          actions: :@reactive_own_actions,
          state_keys: :@reactive_own_state_keys,
          collections: :@reactive_own_collections,
          computes: :@reactive_own_computes,
          # Completion bindings — reactive_on_complete (issue #226).
          on_completes: :@reactive_own_on_completes,
          record_key: :@reactive_own_record_key,
          # Form-field namespace — reactive_scope (issue #180).
          scope: :@reactive_own_scope,
          # Dirty-tracking config — reactive_dirty (issue #184).
          dirty: :@reactive_own_dirty,
          # Deferred reply segments — reactive_lazy (issue #165).
          lazy: :@reactive_own_lazy,
          # Mount on first use — reactive_dormant (issue #274).
          dormant: :@reactive_own_dormant,
          # Enter/exit/update effects — reactive_effects (issue #215).
          effects: :@reactive_own_effects,
          # verify_authorized opt-out (issue #168): a scalar bare flag (skip the
          # WHOLE component) plus a list of named actions.
          skip_all: :@reactive_own_skip_all,
          skip_actions: :@reactive_own_skip_actions
        }.freeze

        # The identity-side hot-path memos swept by bump! (see the contract
        # above). Owned by Component::Identity; invalidated here.
        HOT_PATH_MEMOS = %i[@reactive_record_ivar @reactive_state_ivars].freeze

        # Serializes generation bumps so two concurrent class definitions can't
        # lose an increment (a resolution memoized between the two writes must
        # see a THIRD generation, not the second one again). Reads stay bare —
        # the resolution compare tolerates staleness (it just recomputes).
        WRITE_MUTEX = Mutex.new

        # Frozen empties for the no-declaration branches of resolve_* — the
        # merge/+ still returns a fresh, per-class copy.
        EMPTY_HASH = {}.freeze
        EMPTY_LIST = [].freeze

        @generation = 0

        class << self
          # The process-wide registry generation. Monotonic; never reset (a
          # reloaded class carries no cache ivars, so it rebuilds regardless).
          attr_reader :generation

          # -- writes (all bump) ------------------------------------------------

          # Store `key => value` in a Hash-shaped registry (actions,
          # collections, computes). Returns the value, like the Hash#[]= the
          # declarations used pre-#115.
          def write_entry(klass, kind, key, value)
            own!(klass, kind) { {} }[key] = value
            bump!(klass)
            value
          end

          # Append values to a List-shaped registry (state_keys). Keeps the
          # pre-#115 concat semantics verbatim: declaration order, duplicates
          # included.
          def append(klass, kind, values)
            own!(klass, kind) { [] }.concat(values)
            bump!(klass)
          end

          # Set a Scalar-shaped registry (record_key). The nearest declaration
          # up the ancestry wins at resolve time.
          def write_scalar(klass, kind, value)
            klass.instance_variable_set(OWN_IVARS.fetch(kind), value)
            bump!(klass)
            value
          end

          # -- resolution (all memoized against the generation) -----------------
          #
          # `reader` is the PUBLIC reader to walk the superclass through
          # (e.g. :reactive_actions) — the walk must go through the public
          # method so each ancestor memoizes its own resolution and a bare
          # non-Component superclass (respond_to? false) terminates it.

          # Hash-shaped: ancestors-first merge, nearest declaration winning per
          # key — same key ordering Hash#merge gives the pre-#115 snapshot-dup
          # (inherited entries keep their position, own keys append).
          def resolve_hash(klass, kind, reader)
            fetch(klass, kind) do
              inherited = inherited_value(klass, reader)
              own = own(klass, kind)
              # FROZEN (issue #186): the resolved hash is the public dispatch table
              # (reactive_actions[:x] is the default-deny source of truth) — handing
              # out a mutable memo would let a caller corrupt it. Mutation raises.
              (inherited || EMPTY_HASH).merge(own || EMPTY_HASH).freeze
            end
          end

          # List-shaped: ancestors' entries first, own appended.
          def resolve_list(klass, kind, reader)
            fetch(klass, kind) do
              inherited = inherited_value(klass, reader)
              own = own(klass, kind)
              (inherited || EMPTY_LIST) + (own || EMPTY_LIST)
            end
          end

          # Scalar-shaped: own declaration if present (even one an ancestor
          # would override), else the nearest ancestor's resolution, else nil.
          def resolve_scalar(klass, kind, reader)
            fetch(klass, kind) do
              if klass.instance_variable_defined?(OWN_IVARS.fetch(kind))
                klass.instance_variable_get(OWN_IVARS.fetch(kind))
              else
                inherited_value(klass, reader)
              end
            end
          end

          private

          def own(klass, kind)
            klass.instance_variable_get(OWN_IVARS.fetch(kind))
          end

          # The class's own storage for `kind`, initialized from the block on
          # first write.
          def own!(klass, kind)
            ivar = OWN_IVARS.fetch(kind)
            klass.instance_variable_get(ivar) || klass.instance_variable_set(ivar, yield)
          end

          # Invalidate every resolution memo in the process (generation bump)
          # and sweep the hot-path identity memos off the writing class's
          # family (see the contract in the module doc).
          def bump!(klass)
            WRITE_MUTEX.synchronize { @generation += 1 }
            sweep_hot_path_memos(klass)
          end

          def sweep_hot_path_memos(klass)
            HOT_PATH_MEMOS.each do
              klass.remove_instance_variable(it) if klass.instance_variable_defined?(it)
            end
            klass.subclasses.each { sweep_hot_path_memos(it) }
          end

          # The generation-checked per-class memo: a cache built at an older
          # generation is discarded wholesale and rebuilt lazily per kind.
          def fetch(klass, kind)
            cache = resolution_cache(klass)
            cache.fetch(kind) { cache[kind] = yield }
          end

          def resolution_cache(klass)
            generation = @generation
            if klass.instance_variable_get(:@reactive_registry_generation) == generation
              klass.instance_variable_get(:@reactive_registry_cache)
            else
              # Cache before generation: a concurrent reader that sees the new
              # generation must find the new (empty) cache, never the stale one.
              cache = klass.instance_variable_set(:@reactive_registry_cache, {})
              klass.instance_variable_set(:@reactive_registry_generation, generation)
              cache
            end
          end

          def inherited_value(klass, reader)
            sup = klass.superclass
            sup.public_send(reader) if sup.respond_to?(reader)
          end
        end
      end
    end
  end
end
