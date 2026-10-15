# frozen_string_literal: true

module Phlex
  module Reactive
    class Doctor
      # Ractor mode (zoolutions/phlex-reactive#364): a non-main Ractor can read
      # phlex-reactive's configuration once it is finalized and every setting
      # is Ractor-shareable, and the request path writes no class only when
      # every component class was loaded, instrumented and warmed at boot,
      # which needs eager loading.
      #
      # Advisory only (never ✗): no app has to run Ractors, and Rails, the
      # ActiveSupport::MessageVerifier behind Phlex::Reactive.verifier, and
      # Phlex rendering still block it upstream. Never loads a server.
      module RactorReadiness
        UPSTREAM = "Ractor mode still waits on Rails, on ActiveSupport (the verifier is an " \
                   "ActiveSupport::MessageVerifier) and on Phlex rendering (yippee-fun/phlex#1055)"

        SHARE_FIX = "Define each as a capture-free lambda in a module or class body, which " \
                    "Phlex::Reactive.finalize! can make Ractor-shareable, or leave Ractor mode off."

        def self.included(base)
          base.extend(ClassMethods)
        end

        module ClassMethods
          # Setting => the class of its value, for every configuration reader
          # (Phlex::Reactive::CONFIG_READERS) whose value is not
          # Ractor-shareable. The verifier is left out: it is never shareable.
          def unshareable_settings
            Phlex::Reactive::CONFIG_READERS.each_with_object({}) do |reader, out|
              value = Phlex::Reactive.public_send(reader)
              out[reader] = value.class unless Phlex::Reactive::Shareable.shareable?(value)
            end
          end

          def eager_load? = defined?(::Rails) && ::Rails.application ? ::Rails.application.config.eager_load : false
        end

        def ractor_readiness_check(eager_load: Doctor.eager_load?, finalized: Phlex::Reactive.finalized?,
                                   unshareable: Doctor.unshareable_settings)
          if !eager_load
            advise("eager loading is off: Ractor mode needs every component loaded and prepared at boot",
              "config.eager_load = true (the production default)")
          elsif !finalized
            advise("the configuration is not finalized",
              "Boot through the engine (it calls Phlex::Reactive.finalize! once the app's initializers have run), " \
              "or call Phlex::Reactive.finalize! at the end of your own boot.")
          elsif unshareable.any?
            names = unshareable.map { |name, klass| "#{name} (#{klass})" }.join(", ")
            advise("#{unshareable.size} settings hold a value a non-main Ractor cannot read: #{names}", SHARE_FIX)
          else
            Check.new(:ok, "the configuration is finalized and Ractor-shareable; #{UPSTREAM}", name: :ractor_readiness)
          end
        end

        private

        def advise(message, fix) = Check.new(:unknown, "Ractor mode: #{message}", name: :ractor_readiness, fix:)
      end
    end
  end
end
