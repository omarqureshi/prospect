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
  spec.homepage    = "https://github.com/omarqureshi/prospect"

  spec.metadata = {
    # Links the published package to the repository, which is also what lets a
    # workflow in another repo be granted read access to it.
    "github_repo"       => "ssh://github.com/omarqureshi/prospect",
    "source_code_uri"   => spec.homepage,
    "changelog_uri"     => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "rubygems_mfa_required" => "true"
  }

  spec.required_ruby_version = ">= 3.3"
  spec.files = Dir["lib/**/*.rb", "exe/*", "README.md", "DESIGN.md", "CHANGELOG.md"]
  spec.bindir = "exe"
  spec.executables = ["prospect"]
  spec.require_paths = ["lib"]

  spec.add_dependency "sorbet-runtime"
  spec.add_dependency "rack", "~> 3.0"

  # NOT declared, on purpose:
  #   jwt          — only Prospect::Authorizer needs it, and only that unit
  #                  installs it. Requiring it here would put a gem in every
  #                  service's bundle to serve one of them.
  #   aws-cdk-lib  — only `require "prospect/cdk"` needs it, and it drags in a
  #     constructs   Node sidecar that must stay out of a Lambda cold start.
end
