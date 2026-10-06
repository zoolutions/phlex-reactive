# frozen_string_literal: true

module Phlex
  module Reactive
    class Doctor
      # Falcon serves each request as a fiber on one thread (issue #321). Under
      # Rails' default `config.active_support.isolation_level = :thread`, all
      # thread-keyed state — CurrentAttributes, IsolatedExecutionState, the lock
      # on the connection transactional tests pin, anything in Thread.current —
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

        FIBER_FIX = "Set it in config/application.rb:\n  " \
                    "config.active_support.isolation_level = :fiber\n" \
                    "Under :thread, thread-keyed state (CurrentAttributes, IsolatedExecutionState, " \
                    "Thread.current) is shared by every request Falcon serves on that thread."

        def self.included(base)
          base.extend(ClassMethods)
        end

        module ClassMethods
          # The server gem serving the app: the only one loaded, else the only
          # one bundled. nil when Falcon is present beside another server and
          # neither is singled out; :none when no Falcon is anywhere.
          def detect_server(bundled: bundled_servers, loaded: loaded_servers)
            return loaded.first if loaded.one?
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
              fix: "If Falcon serves it: #{FIBER_FIX}")
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
