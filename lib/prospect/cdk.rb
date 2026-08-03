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

        @anonymous      = Array(@props.dig(:authorizer, :anonymous)).map(&:to_s)
        @authorizer_kind = @props.dig(:authorizer, :kind)
        @authorizer      = build_authorizer(@props[:authorizer])

        @api = AWSCDK::APIGatewayv2::HttpAPI.new(self, "Api", api_props)
        units.each { |unit| add_unit(unit) }
        add_dns_record if @props[:domain]
      end

      # Look a unit's function up by name, for grants:
      #   table.grant_read_write_data(api.function(:posts))
      def function(name) = @functions.fetch(name.to_s)

      # The public base URL: the custom domain when there is one, otherwise the
      # generated API Gateway endpoint. Generated clients read this, so it must
      # be whichever one callers will actually use.
      def url
        @props[:domain] ? "https://#{@props.dig(:domain, :name)}" : @api.url
      end

      def domain_name = @domain_name

      private

      # A custom domain needs a us-east-1 ACM certificate for CloudFront-fronted
      # APIs; for a regional HTTP API the cert must live in the API's own region.
      # Passing the cert in rather than creating it keeps that decision — and the
      # cross-region dance — with the caller.
      def api_props
        return {} unless @props[:domain]

        cfg = @props[:domain]
        @domain_name = AWSCDK::APIGatewayv2::DomainName.new(self, "Domain", {
          domain_name: cfg.fetch(:name),
          certificate: cfg.fetch(:certificate)
        })
        { default_domain_mapping: { domain_name: @domain_name } }
      end

      # Looked up by attributes rather than HostedZone.from_lookup on purpose:
      # a lookup needs AWS credentials at synth time, which makes `cdk synth`
      # non-deterministic and breaks it offline and in CI.
      def add_dns_record
        cfg = @props[:domain]
        zone = cfg[:hosted_zone] || AWSCDK::Route53::HostedZone.from_hosted_zone_attributes(
          self, "Zone",
          { hosted_zone_id: cfg.fetch(:hosted_zone_id), zone_name: cfg.fetch(:zone_name) }
        )

        AWSCDK::Route53::ARecord.new(self, "Alias", {
          zone: zone,
          record_name: cfg.fetch(:name),
          target: AWSCDK::Route53::RecordTarget.from_alias(
            AWSCDK::Route53Targets::APIGatewayv2DomainProperties.new(
              @domain_name.regional_domain_name, @domain_name.regional_hosted_zone_id
            )
          )
        })
      end

      # Shared with the packager (Prospect::Units), so the set of functions
      # synthesised here can never diverge from the set of artifacts built —
      # which would otherwise deploy a function whose code does not exist.
      def units
        Units.for(@router, granularity: @props[:granularity], mount: @mount)
      end

      def add_unit(unit)
        name = unit.name
        fn = build_function(name, unit.procedures)
        @functions[name] = fn

        integration = AWSCDK::APIGatewayv2Integrations::HttpLambdaIntegration.new(
          "#{logical(name)}Integration", fn
        )

        routes_for(unit).each do |path, authorizer|
          props = { path: path,
                    methods: [AWSCDK::APIGatewayv2::HttpMethod::ANY],
                    integration: integration }
          props[:authorizer] = authorizer if authorizer
          @api.add_routes(props)
        end
      end

      # A JWT authorizer attaches per ROUTE, so a greedy `/rpc/posts/{proxy+}`
      # cannot protect `posts.create` while leaving `posts.feed` open. When a
      # unit's procedures disagree, it gets one exact route each; when they
      # agree, it keeps the single greedy route.
      #
      # Route count is the cost, and API Gateway has a per-API quota — worth
      # watching on an app with many mixed services.
      def routes_for(unit)
        return [[unit.route, nil]] unless @authorizer

        # A LAMBDA authorizer sees rawPath, so it decides per procedure and the
        # route can stay greedy. A JWT authorizer only attaches per route, so a
        # unit mixing public and protected procedures has to be split into one
        # exact route each.
        return [[unit.route, @authorizer]] if @authorizer_kind == :lambda

        public_, protected_ = unit.procedures.partition { |p| anonymous?(p) }
        return [[unit.route, nil]] if protected_.empty?
        return [[unit.route, @authorizer]] if public_.empty?

        unit.procedures.map do |p|
          ["#{@mount}/#{p.path}/#{p.name}", anonymous?(p) ? nil : @authorizer]
        end
      end

      def anonymous?(procedure) = @anonymous.include?(procedure.id)

      # LIMITATION worth knowing before relying on this: an API Gateway v2 JWT
      # authorizer is all-or-nothing. It rejects a request with no token, and a
      # route without one receives no verified claims at all. There is no
      # "verify if present".
      #
      # So a procedure listed in `anonymous:` can never see the caller, even when
      # they are signed in — which breaks anything that is public but
      # viewer-dependent. bookface has four of those (`posts.get` computes
      # `editable`, `reactions.mine` returns the viewer's own reactions). The
      # fix is a Lambda authorizer that allows unauthenticated through while
      # attaching claims when present; that is not built.
      def build_authorizer(config)
        return nil if config.nil?

        case config[:kind]
        when :jwt
          AWSCDK::APIGatewayv2Authorizers::HttpJwtAuthorizer.new(
            "#{@props.fetch(:id_prefix, 'Api')}Jwt",
            config.fetch(:issuer),
            { jwt_audience: Array(config.fetch(:audience)) }
          )
        when :lambda
          # Optional auth: allows an anonymous caller through on the declared
          # public procedures while still attaching verified claims when a token
          # is present. An API Gateway JWT authorizer cannot express that.
          fn = authorizer_function(config)
          AWSCDK::APIGatewayv2Authorizers::HttpLambdaAuthorizer.new(
            "#{@props.fetch(:id_prefix, 'Api')}Auth", fn,
            { response_types: [AWSCDK::APIGatewayv2Authorizers::HttpLambdaResponseType::SIMPLE],
              # Cached per (identity source, route). Zero would invoke the
              # authorizer on every request; the default caches by token.
              results_cache_ttl: config[:cache_ttl] || AWSCDK::Duration.seconds(300),
              identity_source: ["$request.header.Authorization"] }
          )
        when :user_pool
          AWSCDK::APIGatewayv2Authorizers::HttpUserPoolAuthorizer.new(
            "#{@props.fetch(:id_prefix, 'Api')}Pool", config.fetch(:user_pool)
          )
        else
          raise ArgumentError, "unknown authorizer kind #{config[:kind].inspect}"
        end
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
          # Baked in at synth time so no cold start spends anything walking the
          # type graph to recompute it (Dispatcher#schema_hash prefers this).
          environment:  { "PROSPECT_UNIT" => name, "PROSPECT_SCHEMA_HASH" => schema_hash }
                          .merge(@props[:environment] || {})
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

      # Its own small function, built like any other unit. `identity_source`
      # above means API Gateway caches by Authorization header — so an anonymous
      # request (no header) is NOT cached, and every one invokes this.
      def authorizer_function(config)
        AWSCDK::Lambda::Function.new(self, "Authorizer", {
          runtime:      @props[:runtime] || AWSCDK::Lambda::Runtime.RUBY_4_0,
          architecture: @props[:architecture] || AWSCDK::Lambda::Architecture.X86_64,
          handler:      "handler.handle",
          code:         AWSCDK::Lambda::Code.from_asset(asset_path_for("authorizer")),
          memory_size:  config[:memory_size] || 512,
          timeout:      AWSCDK::Duration.seconds(config[:timeout_seconds] || 10),
          environment: {
            "PROSPECT_ISSUER"    => config.fetch(:issuer),
            "PROSPECT_AUDIENCE"  => Array(config.fetch(:audience)).join(","),
            "PROSPECT_ANONYMOUS" => @anonymous.join(","),
            "PROSPECT_MOUNT"     => @mount
          }
        })
      end

      def schema_hash
        @schema_hash ||= IR.extract(@router)["schema_hash"]
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
