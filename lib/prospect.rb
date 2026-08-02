# frozen_string_literal: true

require "sorbet-runtime"

require_relative "prospect/version"
require_relative "prospect/error"
require_relative "prospect/router"
require_relative "prospect/dispatcher"
require_relative "prospect/rack_app"
require_relative "prospect/lambda"
require_relative "prospect/ir"
require_relative "prospect/emit/typescript"

# Prospect — a tRPC-shaped RPC layer for Ruby. See DESIGN.md.
#
# This is the walking skeleton from DESIGN.md §9: the router DSL, one dispatcher,
# and the Rack transport. Not yet built — IR extraction, the emitters, the CDK
# construct, and the Lambda adapter. It exists to make bookface-rpc run locally,
# which is the point at which the DSL stops being hypothetical.
