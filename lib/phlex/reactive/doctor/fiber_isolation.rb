# frozen_string_literal: true

module Phlex
  module Reactive
    class Doctor
      # Falcon serves each request as a fiber on one thread (issue #321). Under
      # Rails' default `config.active_support.isolation_level = :thread`, all
      # thread-keyed state — CurrentAttributes, IsolatedExecutionState, the lock
      # on the connection transactional tests pin, thread variables —
      # is shared by every request on that thread. phlex-reactive's own
      # request state is fiber-local and unaffected; the app around it is not.
      #
      # Detection never loads a server: it reads the bundle (Gem.loaded_specs)
      # and which server constants are already defined.
      module FiberIsolation
        # Server gem => the constant it defines once loaded.
        SERVERS = {
          "falcon" => "Falcon",
          "puma" => "Puma",
          "unicorn" => "Unicorn",
          "pitchfork" => "Pitchfork",
          "passenger" => "PhusionPassenger",
          "thin" => "Thin",
          "iodine" => "Iodine"
        }.freeze

        FIBER_FIX = "Under :thread, thread-keyed state (CurrentAttributes, IsolatedExecutionState, " \
                    "thread variables) is shared by every request Falcon serves on a thread. " \
                    "Set in config/application.rb:\n  config.active_support.isolation_level = :fiber"

        def self.included(base)
          base.extend(ClassMethods)
        end

        module ClassMethods
          # The server gem serving the app: Falcon when it is the only one
          # loaded, else the only one bundled. A lone loaded non-Falcon server
          # only counts when Falcon isn't bundled — the doctor runs as a rake
          # task, where "loaded" is whatever Bundler.require pulled in (Rails'
          # default `gem "puma"` beside `gem "falcon", require: false`). nil
          # when Falcon is present beside another server and neither is
          # singled out; :none when no Falcon is anywhere.
          def detect_server(bundled: bundled_servers, loaded: loaded_servers)
            return loaded.first if loaded.one? && (loaded.first == "falcon" || bundled.exclude?("falcon"))
            return bundled.first if bundled.one?

            (bundled | loaded).include?("falcon") ? nil : :none
          end

          def bundled_servers
            SERVERS.keys.select { Gem.loaded_specs.key?(it) }
          end

          def loaded_servers
            SERVERS.select { |_gem, const| Object.const_defined?(const) }.keys
          end

          def isolation_level
            ActiveSupport::IsolatedExecutionState.isolation_level
          end
        end

        def fiber_isolation_check(server: Doctor.detect_server, isolation: Doctor.isolation_level)
          if isolation == :fiber
            Check.new(:ok, "config.active_support.isolation_level is :fiber", name: :fiber_isolation)
          elsif server == "falcon"
            Check.new(:fail, "Falcon serves requests as fibers, but config.active_support.isolation_level " \
                             "is :#{isolation}", name: :fiber_isolation, fix: FIBER_FIX)
          elsif server.nil?
            Check.new(:unknown, "Falcon is in the bundle beside another server; could not tell which serves " \
                                "the app (isolation_level is :#{isolation})", name: :fiber_isolation,
              fix: "If Falcon serves the app: #{FIBER_FIX}")
          else
            Check.new(:ok, "#{server_label(server)}; :#{isolation} isolation is fine", name: :fiber_isolation)
          end
        end

        private

        def server_label(server)
          server == :none ? "no Falcon in the bundle" : "#{server} does not serve requests as fibers"
        end
      end
    end
  end
end
