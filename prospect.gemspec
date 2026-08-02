# frozen_string_literal: true

require_relative "lib/prospect/version"

Gem::Specification.new do |spec|
  spec.name        = "prospect"
  spec.version     = Prospect::VERSION
  spec.authors     = ["Omar Qureshi"]
  spec.email       = ["omar@omarqureshi.net"]
  spec.summary     = "A tRPC-shaped RPC layer for Ruby"
  spec.description = "Typed procedures from Sorbet T::Structs, with generated " \
                     "clients and Lambda deployment. See DESIGN.md."
  spec.license     = "MIT"

  spec.required_ruby_version = ">= 3.3"
  spec.files = Dir["lib/**/*.rb", "DESIGN.md"]
  spec.require_paths = ["lib"]

  spec.add_dependency "sorbet-runtime"
  spec.add_dependency "rack", "~> 3.0"
end
