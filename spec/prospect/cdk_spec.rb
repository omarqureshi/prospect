# frozen_string_literal: true

# Synth-level: no AWS account, no deploy, no credentials. `Template.from_stack`
# renders the CloudFormation the construct would produce and we assert on it.
#
# Tagged and skipped when aws-cdk-lib isn't installed, because loading it pulls
# in jsii and a Node sidecar — that must never be a requirement for running the
# core suite. Skipping LOUDLY: a green run that silently never exercised the
# construct is worse than a red one.
begin
  require "prospect/cdk"
  CDK_AVAILABLE = true
rescue LoadError => e
  CDK_AVAILABLE = false
  CDK_LOAD_ERROR = e.message
end

RSpec.describe "Prospect::CDK::Service", :cdk do
  if !CDK_AVAILABLE
    it "synthesises the router" do
      skip "aws-cdk-lib not installed (#{CDK_LOAD_ERROR}) — run `bundle install --with cdk`"
    end
  else
    # Code.from_asset needs a real directory per unit. Build them once in a
    # tmpdir rather than committing stub handlers for every granularity.
    before(:all) do
      require "tmpdir"
      require "fileutils"
      @asset_root = Dir.mktmpdir("prospect-cdk")
      names = ["app"] +
              Fixtures::AppRouter.procedures.map { |p| p.path.to_s } +
              Fixtures::AppRouter.procedures.map(&:id)
      names.uniq.each do |n|
        FileUtils.mkdir_p(File.join(@asset_root, n))
        File.write(File.join(@asset_root, n, "handler.rb"), "def handle(event:, context:) = {}\n")
      end
    end

    after(:all) { FileUtils.remove_entry(@asset_root) if @asset_root }

    def synth(granularity: :per_router, **props)
      app   = AWSCDK::App.new
      stack = AWSCDK::Stack.new(app, "TestStack")
      Prospect::CDK::Service.new(stack, "Api", {
        router: Fixtures::AppRouter, granularity: granularity, code_root: @asset_root
      }.merge(props))
      AWSCDK::Assertions::Template.from_stack(stack)
    end

    def resources(template, type)
      template.find_resources(type).values
    end

    describe "granularity" do
      # The fixture has two routers (echo, other) and one procedure asking for
      # its own function (other.touch is :dedicated).
      it "creates one function per router, plus dedicated procedures" do
        synth(granularity: :per_router).resource_count_is("AWS::Lambda::Function", 2)
      end

      it "creates one function for the whole app when :single" do
        synth(granularity: :single).resource_count_is("AWS::Lambda::Function", 1)
      end

      it "creates one function per procedure when :per_procedure" do
        expected = Fixtures::AppRouter.procedures.length
        synth(granularity: :per_procedure).resource_count_is("AWS::Lambda::Function", expected)
      end
    end

    # The property that makes granularity a deploy-time flag rather than a
    # rewrite: whichever shape is chosen, the same procedure paths are served,
    # so no generated client changes. DESIGN.md §6.
    describe "granularity is invisible to clients" do
      def routes(template)
        resources(template, "AWS::ApiGatewayV2::Route").map { |r| r["Properties"]["RouteKey"] }
      end

      it "serves every procedure path under all three granularities" do
        %i[single per_router per_procedure].each do |g|
          keys = routes(synth(granularity: g)).join(" ")
          expect(keys).to include("/rpc"), "granularity #{g} did not mount /rpc"
        end
      end

      it "routes a dedicated procedure exactly, so it peels off without a client change" do
        keys = routes(synth(granularity: :per_router))
        expect(keys).to include("ANY /rpc/other/touch")
        expect(keys).to include("ANY /rpc/echo/{proxy+}")
      end
    end

    describe "function configuration" do
      it "defaults to x86_64, because emulated arm64 builds measured 41x slower" do
        synth.has_resource_properties("AWS::Lambda::Function", { "Architectures" => ["x86_64"] })
      end

      it "defaults memory to 1024, which cold-start measurements showed is cost-neutral" do
        synth.has_resource_properties("AWS::Lambda::Function", { "MemorySize" => 1024 })
      end

      it "honours an explicit architecture" do
        template = synth(architecture: AWSCDK::Lambda::Architecture.ARM_64)
        template.has_resource_properties("AWS::Lambda::Function", { "Architectures" => ["arm64"] })
      end

      # Procedure-level deploy: beats the router's, which beats the defaults.
      it "takes the largest requested memory for a shared unit" do
        memories = resources(synth, "AWS::Lambda::Function")
                   .map { |f| f["Properties"]["MemorySize"] }
        expect(memories).to all(be >= 512)
      end

      it "tells each function which unit it serves" do
        units = resources(synth, "AWS::Lambda::Function")
                .map { |f| f.dig("Properties", "Environment", "Variables", "PROSPECT_UNIT") }
        expect(units).to contain_exactly("echo", "other.touch")
      end

      # Recomputing it means walking every declared type — fine once at synth,
      # wasteful on every cold start.
      it "bakes the schema hash in, so no cold start recomputes it" do
        hash = Prospect::IR.extract(Fixtures::AppRouter)["schema_hash"]
        synth.has_resource_properties("AWS::Lambda::Function", {
          "Environment" => { "Variables" => { "PROSPECT_SCHEMA_HASH" => hash } }
        })
      end

      it "merges caller-supplied environment" do
        template = synth(environment: { "TABLE" => "posts" })
        template.has_resource_properties("AWS::Lambda::Function", {
          "Environment" => { "Variables" => { "TABLE" => "posts" } }
        })
      end
    end

    describe "the API" do
      it "creates exactly one front door for all units" do
        synth.resource_count_is("AWS::ApiGatewayV2::Api", 1)
      end

      it "gives every unit an integration" do
        template = synth
        expect(resources(template, "AWS::ApiGatewayV2::Integration").length).to eq(2)
      end
    end

    describe "the construct's own API" do
      it "exposes functions by unit name for granting" do
        stack = AWSCDK::Stack.new(AWSCDK::App.new, "S")
        svc = Prospect::CDK::Service.new(stack, "Api", {
          router: Fixtures::AppRouter, code_root: @asset_root
        })
        expect(svc.function(:echo)).to be_a(AWSCDK::Lambda::Function)
        expect { svc.function(:nope) }.to raise_error(KeyError)
      end
    end

    # The invariant that makes sharing Prospect::Units worth it: if these two
    # ever disagree, you deploy a function whose artifact was never built.
    it "synthesises exactly the units the packager would build" do
      units = Prospect::Units.for(Fixtures::AppRouter, granularity: :per_router)
      synthesised = resources(synth, "AWS::Lambda::Function")
                    .map { |f| f.dig("Properties", "Environment", "Variables", "PROSPECT_UNIT") }
      expect(synthesised).to match_array(units.map(&:name))
    end

    describe "the JWT authorizer" do
      def with_auth(anonymous:, **props)
        synth(authorizer: { kind: :jwt, issuer: "https://issuer.example",
                            audience: ["client-id"], anonymous: anonymous }, **props)
      end

      def routes(template)
        resources(template, "AWS::ApiGatewayV2::Route").map { |r| r["Properties"] }
      end

      it "creates a JWT authorizer" do
        with_auth(anonymous: []).resource_count_is("AWS::ApiGatewayV2::Authorizer", 1)
      end

      it "creates none when not configured" do
        synth.resource_count_is("AWS::ApiGatewayV2::Authorizer", 0)
      end

      it "protects every route when nothing is anonymous" do
        rs = routes(with_auth(anonymous: []))
        expect(rs).to all(include("AuthorizationType" => "JWT"))
      end

      it "leaves a wholly-anonymous unit unprotected on its greedy route" do
        rs = routes(with_auth(anonymous: Fixtures::AppRouter.procedures.map(&:id)))
        expect(rs.map { |r| r["RouteKey"] }).to include("ANY /rpc/echo/{proxy+}")
        expect(rs.none? { |r| r["AuthorizationType"] == "JWT" }).to be(true)
      end

      # A greedy route cannot protect one procedure and expose another, so a
      # mixed unit has to be split into exact routes.
      it "splits a mixed unit into per-procedure routes" do
        rs = routes(with_auth(anonymous: ["echo.ping"]))
        keys = rs.to_h { |r| [r["RouteKey"], r["AuthorizationType"]] }

        expect(keys).to include("ANY /rpc/echo/ping" => "NONE")
        expect(keys).to include("ANY /rpc/echo/secret" => "JWT")
        expect(keys.keys).not_to include("ANY /rpc/echo/{proxy+}")
      end

      it "still routes every procedure after splitting" do
        keys = routes(with_auth(anonymous: ["echo.ping"])).map { |r| r["RouteKey"] }
        Fixtures::AppRouter.procedures.select { |p| p.path.to_s == "echo" }.each do |p|
          expect(keys).to include("ANY /rpc/echo/#{p.name}")
        end
      end

      it "rejects an unknown authorizer kind" do
        expect { synth(authorizer: { kind: :magic }) }
          .to raise_error(ArgumentError, /unknown authorizer kind/)
      end
    end

    describe "a custom domain" do
      def with_domain
        stack = AWSCDK::Stack.new(AWSCDK::App.new, "D", { env: { region: "eu-west-2", account: "111111111111" } })
        cert = AWSCDK::CertificateManager::Certificate.from_certificate_arn(
          stack, "Cert", "arn:aws:acm:eu-west-2:111111111111:certificate/abc"
        )
        svc = Prospect::CDK::Service.new(stack, "Api", {
          router: Fixtures::AppRouter, code_root: @asset_root,
          domain: { name: "rpc.example.net", certificate: cert,
                    hosted_zone_id: "Z123", zone_name: "example.net" }
        })
        [AWSCDK::Assertions::Template.from_stack(stack), svc]
      end

      it "creates a domain name and maps the API to it" do
        template, = with_domain
        template.resource_count_is("AWS::ApiGatewayV2::DomainName", 1)
        template.resource_count_is("AWS::ApiGatewayV2::ApiMapping", 1)
      end

      it "creates a Route 53 alias record" do
        template, = with_domain
        template.has_resource_properties("AWS::Route53::RecordSet", {
          "Name" => "rpc.example.net.", "Type" => "A"
        })
      end

      # Generated clients read this, so it must be the URL callers actually use.
      it "reports the custom domain as the service URL" do
        _, svc = with_domain
        expect(svc.url).to eq("https://rpc.example.net")
      end

      it "creates none of it when no domain is configured" do
        synth.resource_count_is("AWS::ApiGatewayV2::DomainName", 0)
        synth.resource_count_is("AWS::Route53::RecordSet", 0)
      end
    end

    it "rejects an unknown granularity at synth time" do
      expect { synth(granularity: :whatever) }
        .to raise_error(ArgumentError, /unknown granularity/)
    end
  end
end
