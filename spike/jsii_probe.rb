# jsii Ruby target conformance probe, driven by what Rpc::CDK::Service needs.
#
# Every probe here corresponds to something the RPC framework's construct must
# do. A failure is a design constraint, not a curiosity: if dynamic child
# generation or token interpolation doesn't work, §6 of DESIGN.md needs redoing.
#
#   ruby spike/jsii_probe.rb

require "aws-cdk-lib"
require "constructs"

RESULTS = []

def probe(name)
  value = yield
  RESULTS << [:pass, name, nil]
  value
rescue => e
  RESULTS << [:fail, name, "#{e.class}: #{e.message.lines.first&.strip}"]
  nil
end

HANDLER_DIR = File.expand_path("handler", __dir__)

# --- 1. Can we subclass Construct (not just Stack) and generate children from data?
# This is the single most load-bearing question. Rpc::CDK::Service is a
# Construct subclass that creates N Lambdas from the IR at synth time.
class RpcService < Constructs::Construct
  attr_reader :functions

  def initialize(scope, id, props = {})
    super(scope, id)
    @functions = {}

    props.fetch(:units).each do |unit|
      @functions[unit] = AWSCDK::Lambda::Function.new(self, "Fn#{unit.capitalize}", {
        runtime:      AWSCDK::Lambda::Runtime.RUBY_4_0,
        architecture: AWSCDK::Lambda::Architecture.ARM_64,
        handler:      "handler.handle",
        code:         AWSCDK::Lambda::Code.from_asset(HANDLER_DIR),
        memory_size:  512,
        timeout:      AWSCDK::Duration.seconds(10)
      })
    end
  end
end

app   = probe("App.new")            { AWSCDK::App.new }
stack = probe("Stack.new")          { AWSCDK::Stack.new(app, "ProbeStack") }

# --- 2. Static properties vs enums: are they accessed differently?
probe("Runtime.RUBY_4_0 (static property, dot)")       { AWSCDK::Lambda::Runtime.RUBY_4_0 }
probe("Architecture::ARM_64 (const)")                  { AWSCDK::Lambda::Architecture::ARM_64 }
probe("Architecture.ARM_64 (method)")                  { AWSCDK::Lambda::Architecture.ARM_64 }
probe("RemovalPolicy::DESTROY (enum, colon)")          { AWSCDK::RemovalPolicy::DESTROY }
probe("Duration.seconds")                              { AWSCDK::Duration.seconds(10) }

# --- 3. Construct subclass + dynamic children
svc = probe("Construct subclass w/ N dynamic children") do
  RpcService.new(stack, "Api", { units: %w[users posts reports] })
end

# --- 4. Token interpolation — env vars carrying another construct's attribute
table = probe("DynamoDB TableV2") do
  AWSCDK::DynamoDB::TableV2.new(stack, "Posts", {
    partition_key:  { name: "id", type: AWSCDK::DynamoDB::AttributeType::STRING },
    removal_policy: AWSCDK::RemovalPolicy::DESTROY
  })
end

probe("token passed directly as env value") do
  raise "no table" unless table
  AWSCDK::Lambda::Function.new(stack, "TokenDirect", {
    runtime: AWSCDK::Lambda::Runtime.RUBY_4_0,
    handler: "handler.handle",
    code:    AWSCDK::Lambda::Code.from_asset(HANDLER_DIR),
    environment: { "TABLE" => table.table_name }
  })
end

probe("token in Ruby string interpolation") do
  raise "no table" unless table
  interpolated = "prefix-#{table.table_name}"
  raise "interpolation produced #{interpolated.inspect}" unless interpolated.include?("${Token[")
  interpolated
end

# --- 5. Grants: cross-construct wiring that returns a jsii object
probe("table.grant_read_write_data(fn)") do
  raise "no svc/table" unless svc && table
  table.grant_read_write_data(svc.functions["users"])
end

# --- 6. API Gateway v2 — verifying the names DESIGN.md §6 guessed at
http_api = probe("APIGatewayv2::HttpAPI.new") do
  AWSCDK::APIGatewayv2::HttpAPI.new(stack, "HttpApi")
end

integration = probe("APIGatewayv2Integrations::HttpLambdaIntegration.new(id, fn)") do
  raise "no svc" unless svc
  AWSCDK::APIGatewayv2Integrations::HttpLambdaIntegration.new("UsersInt", svc.functions["users"])
end

probe("http_api.add_routes greedy path") do
  raise "no api/integration" unless http_api && integration
  http_api.add_routes({
    path:        "/rpc/users/{proxy+}",
    methods:     [AWSCDK::APIGatewayv2::HttpMethod::ANY],
    integration: integration
  })
end

# --- 7. Synth + assertions: the actual test loop for the framework
template = probe("Assertions::Template.from_stack") do
  AWSCDK::Assertions::Template.from_stack(stack)
end

probe("template.resource_count_is (4 functions)") do
  raise "no template" unless template
  template.resource_count_is("AWS::Lambda::Function", 4)
end

probe("template.has_resource_properties (arm64)") do
  raise "no template" unless template
  template.has_resource_properties("AWS::Lambda::Function", { Architectures: ["arm64"] })
end

probe("app.synth") { app.synth }

# --- report
puts
puts "=" * 72
RESULTS.each do |status, name, err|
  puts format("%-4s %-52s %s", status == :pass ? "PASS" : "FAIL", name, err || "")
end
puts "=" * 72
pass = RESULTS.count { |r| r[0] == :pass }
puts "#{pass}/#{RESULTS.size} passed"
