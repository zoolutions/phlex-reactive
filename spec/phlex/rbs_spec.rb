# frozen_string_literal: true

require "rails_helper"
require "rbs"

# What spec/phlex/rbs_spec.rb compares: the signatures in sig/, and the
# public methods the gem defines.
module RbsSpec
  LIB = File.expand_path("../../lib", __dir__)

  # The public surface: its module or class, and whose methods.
  SURFACES = [
    ["Phlex::Reactive", :singleton],
    ["Phlex::Reactive::Component::DSL::ClassMethods", :instance],
    ["Phlex::Reactive::Streamable", :instance],
    ["Phlex::Reactive::Streamable::ClassMethods", :instance],
    ["Phlex::Reactive::Response", :singleton],
    ["Phlex::Reactive::Response", :instance],
    ["Phlex::Reactive::ParamSchema", :singleton],
    ["Phlex::Reactive::ParamSchema", :instance],
    ["Phlex::Reactive::Store", :singleton],
    ["Phlex::Reactive::Shareable", :singleton]
  ].freeze

  def self.definitions
    loader = RBS::EnvironmentLoader.new
    loader.add(path: Pathname(File.expand_path("../../sig", __dir__)))
    RBS::DefinitionBuilder.new(env: RBS::Environment.from_loader(loader).resolve_type_names)
  end

  def self.signed(name, kind)
    type_name = RBS::TypeName.parse("::#{name}")
    definition = kind == :singleton ? definitions.build_singleton(type_name) : definitions.build_instance(type_name)
    definition.methods.keys
  end

  # The public methods the gem itself defines there: a module also answers
  # Module's, and the engine's namespace what isolate_namespace adds.
  def self.reflected(name, kind)
    mod = Object.const_get(name)
    return mod.public_instance_methods(false) if kind == :instance

    base = mod.is_a?(Class) ? Class : Module
    (mod.public_methods(false) - base.public_instance_methods)
      .select { mod.method(it).source_location&.first&.start_with?(LIB) }
  end
end

# sig/ covers the public surface (zoolutions/phlex-reactive#364): every public
# method of Phlex::Reactive, of a component's class-level DSL, of Streamable
# (instance and class), of Response, of ParamSchema, of Store and of
# Shareable has a signature. A reflection diff: a new
# public method without one fails here, naming it. (`rbs -I sig validate`, in
# the Lint job, checks the signatures themselves.)
RSpec.describe Phlex::Reactive, "RBS signatures" do
  RbsSpec::SURFACES.each do |name, kind|
    it "signs every public #{kind == :singleton ? "class method" : "method"} of #{name}" do
      expect(RbsSpec.reflected(name, kind).sort - RbsSpec.signed(name, kind)).to eq([])
    end
  end
end
