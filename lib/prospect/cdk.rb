# frozen_string_literal: true

# Deliberately NOT required by lib/prospect.rb. Loading this pulls in
# aws-cdk-lib, which pulls in the jsii runtime, which needs a Node sidecar —
# none of which belongs in a Lambda's cold-start path or a local test run.
# Infrastructure code requires it explicitly:
#
#   require "prospect/cdk"
#
# This answers the open question in DESIGN.md §11: the seam is a separate
# require rather than a separate gem, which costs nothing and can become a gem
# later if the dependency ever needs its own release cycle.
require "aws-cdk-lib"
require "constructs"
require "prospect"

module Prospect
  module CDK
    # Synthesises a Prospect router into Lambda functions behind one HTTP API.
    #
    # The router's IR is read **in this process at synth time** — there is no
    # codegen step and no generated infrastructure files, because the CDK app is
    # itself Ruby (DESIGN.md §6). Adding a procedure changes a service file;
    # this construct doesn't change.
    class Service < Constructs::Construct
      DEFAULTS = {
        granularity: :per_router,
        mount_path: "/rpc",
        memory_size: 1024,
        timeout_seconds: 10
      }.freeze

      attr_reader :api, :functions

      def initialize(scope, id, props = {})
        super(scope, id)

        @props     = DEFAULTS.merge(props)
        @router    = @props.fetch(:router)
        @mount     = @props.fetch(:mount_path)
        @functions = {}

        @api = AWSCDK::APIGatewayv2::HttpAPI.new(self, "Api")
        units.each { |unit| add_unit(unit) }
      end

      # Look a unit's function up by name, for grants:
      #   table.grant_read_write_data(api.function(:posts))
      def function(name) = @functions.fetch(name.to_s)

      def url = @api.url

      private

      # [name, [procedures], route] per deployment unit. Granularity is purely a
      # deployment concern — every shape below serves identical procedure paths,
      # so clients cannot tell which was chosen and never regenerate when it
      # changes (DESIGN.md §6).
      def units
        case @props[:granularity]
        when :single
          [["app", @router.procedures, "#{@mount}/{proxy+}"]]
        when :per_procedure
          @router.procedures.map { |p| [p.id, [p], "#{@mount}/#{p.path}/#{p.name}"] }
        when :per_router
          per_router_units
        else
          raise ArgumentError, "unknown granularity #{@props[:granularity].inspect}"
        end
      end

      # One function per mounted router, except procedures that asked for their
      # own via `deploy: { granularity: :dedicated }` — those get an exact route,
      # which API Gateway prefers over the greedy one, so they peel off without
      # changing any client.
      def per_router_units
        grouped = @router.procedures.group_by(&:path)
        grouped.flat_map do |path, procedures|
          dedicated, shared = procedures.partition { |p| p.deploy[:granularity] == :dedicated }

          units = dedicated.map { |p| [p.id, [p], "#{@mount}/#{p.path}/#{p.name}"] }
          units << [path.to_s, shared, "#{@mount}/#{path}/{proxy+}"] if shared.any?
          units
        end
      end

      def add_unit((name, procedures, route))
        name = name.to_s
        fn = build_function(name, procedures)
        @functions[name] = fn

        @api.add_routes({
          path: route,
          methods: [AWSCDK::APIGatewayv2::HttpMethod::ANY],
          integration: AWSCDK::APIGatewayv2Integrations::HttpLambdaIntegration.new(
            "#{logical(name)}Integration", fn
          )
        })
      end

      def build_function(name, procedures)
        AWSCDK::Lambda::Function.new(self, logical(name), {
          runtime:      @props[:runtime] || AWSCDK::Lambda::Runtime.RUBY_4_0,
          # x86_64 by default: building arm64 artifacts on an x86_64 host runs
          # under qemu and measured 41x slower. DESIGN.md §6.
          architecture: @props[:architecture] || AWSCDK::Lambda::Architecture.X86_64,
          handler:      "handler.handle",
          code:         AWSCDK::Lambda::Code.from_asset(asset_path_for(name)),
          memory_size:  setting(procedures, :memory_size),
          timeout:      AWSCDK::Duration.seconds(setting(procedures, :timeout_seconds)),
          environment:  { "PROSPECT_UNIT" => name }.merge(@props[:environment] || {})
        })
      end

      # Procedure-level `deploy:` wins over the router's, which wins over the
      # construct's defaults. Where a unit holds several procedures, the largest
      # requested value wins — undersizing a function is a runtime failure,
      # oversizing is a rounding error on the bill.
      def setting(procedures, key)
        from_procedures = procedures.filter_map { |p| p.deploy[key] }
        from_router     = procedures.map { |p| router_for(p)&.deploy_config&.dig(key) }.compact
        (from_procedures + from_router + [@props.dig(:defaults, key), @props[key]].compact).max
      end

      def router_for(procedure)
        @router.mounted.find { |m| m.path == procedure.path } || @router
      end

      def asset_path_for(name)
        root = @props.fetch(:code_root, "build")
        File.join(root, name.to_s)
      end

      # CloudFormation logical ids must be alphanumeric.
      def logical(name) = name.to_s.split(/[._-]/).map(&:capitalize).join
    end
  end
end
