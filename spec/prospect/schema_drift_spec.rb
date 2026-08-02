# frozen_string_literal: true

require "rack"
require "rack/mock"

# The third layer of drift protection (DESIGN.md §7). The other two — `prospect
# check` in CI and the TypeScript compiler — both act at build time. This one is
# the only thing that catches a client that was correct when it was built and
# has since been outlived by the server: a browser holding cached JS, or a
# service deployed weeks ago.
RSpec.describe "schema drift detection" do
  let(:server_hash) { Prospect::IR.extract(Fixtures::AppRouter)["schema_hash"] }

  def dispatcher(policy) = Prospect::Dispatcher.new(Fixtures::AppRouter, on_schema_mismatch: policy)

  describe "the hash itself" do
    it "is exposed by the dispatcher" do
      expect(dispatcher(:warn).schema_hash).to eq(server_hash)
    end

    # Walking every declared type is fine once and wasteful on every cold start,
    # so the packager/CDK can bake it in.
    it "prefers a value baked in at deploy time over recomputing" do
      original = ENV["PROSPECT_SCHEMA_HASH"]
      ENV["PROSPECT_SCHEMA_HASH"] = "sha256:baked"
      expect(Prospect::Dispatcher.new(Fixtures::AppRouter).schema_hash).to eq("sha256:baked")
    ensure
      ENV["PROSPECT_SCHEMA_HASH"] = original
    end
  end

  describe "policy" do
    it "passes a matching hash through" do
      expect(dispatcher(:reject).check_schema(server_hash)).to be_nil
    end

    # A client that sends nothing is not evidence of drift — the Ruby client and
    # curl both do this.
    it "ignores an absent hash" do
      expect(dispatcher(:reject).check_schema(nil)).to be_nil
      expect(dispatcher(:reject).check_schema("")).to be_nil
    end

    it "rejects a mismatch with 409 and both hashes when asked to" do
      status, body = dispatcher(:reject).check_schema("sha256:stale")
      expect(status).to eq(409)
      expect(body["error"]).to include(
        "code" => "schema_mismatch", "client" => "sha256:stale", "server" => server_hash
      )
    end

    # Default is warn, not reject: a hard failure would break every client
    # already sitting in a browser cache the moment the schema changed, which is
    # a worse outcome than a log line.
    it "warns and proceeds by default" do
      expect { expect(dispatcher(:warn).check_schema("sha256:stale")).to be_nil }
        .to output(/schema mismatch.*sha256:stale/m).to_stderr
    end

    it "can be turned off entirely" do
      expect { expect(dispatcher(:off).check_schema("sha256:stale")).to be_nil }
        .not_to output.to_stderr
    end
  end

  describe "over Rack" do
    def app(policy) = Prospect::RackApp.new(
      Fixtures::AppRouter,
      context_builder: ->(_env) { Fixtures::Context.new(viewer: nil) },
      on_schema_mismatch: policy
    )

    it "accepts a request carrying the current hash" do
      res = Rack::MockRequest.new(app(:reject)).post(
        "/rpc/echo/ping", input: '{"who":"x"}', "HTTP_X_PROSPECT_SCHEMA" => server_hash
      )
      expect(res.status).to eq(200)
    end

    it "rejects a stale client before running any procedure" do
      res = Rack::MockRequest.new(app(:reject)).post(
        "/rpc/echo/ping", input: '{"who":"x"}', "HTTP_X_PROSPECT_SCHEMA" => "sha256:old"
      )
      expect(res.status).to eq(409)
      expect(JSON.parse(res.body).dig("error", "code")).to eq("schema_mismatch")
    end

    # A batch is one request. Checking per item would let some of a stale
    # client's calls succeed and others fail, which is worse than either.
    it "rejects a whole batch, not individual calls" do
      res = Rack::MockRequest.new(app(:reject)).post(
        "/rpc?batch=1",
        input: JSON.generate([{ "id" => "echo.ping", "input" => { "who" => "x" } }]),
        "HTTP_X_PROSPECT_SCHEMA" => "sha256:old"
      )
      expect(res.status).to eq(409)
      expect(JSON.parse(res.body)).to be_a(Hash) # not a per-item array
    end

    it "advertises the current hash on /up so a client can self-check" do
      body = JSON.parse(Rack::MockRequest.new(app(:warn)).get("/up").body)
      expect(body["schema"]).to eq(server_hash)
    end
  end

  describe "over Lambda" do
    def handler(policy) = Prospect::Lambda.handler(
      Fixtures::AppRouter,
      context_builder: ->(_e) { Fixtures::Context.new(viewer: nil) },
      on_schema_mismatch: policy
    )

    def event(headers)
      { "version" => "2.0", "rawPath" => "/rpc/echo/ping",
        "headers" => headers,
        "requestContext" => { "http" => { "method" => "POST" } },
        "body" => '{"who":"x"}', "isBase64Encoded" => false }
    end

    it "accepts the current hash" do
      res = handler(:reject).call(event("x-prospect-schema" => server_hash))
      expect(res["statusCode"]).to eq(200)
    end

    it "rejects a stale one" do
      res = handler(:reject).call(event("x-prospect-schema" => "sha256:old"))
      expect(res["statusCode"]).to eq(409)
    end

    # API Gateway lower-cases header names; a directly-invoked Function URL in a
    # test might not.
    it "reads the header case-insensitively" do
      res = handler(:reject).call(event("X-Prospect-Schema" => "sha256:old"))
      expect(res["statusCode"]).to eq(409)
    end

    it "behaves identically to Rack, as both are adapters over one dispatcher" do
      lambda_status = handler(:reject).call(event("x-prospect-schema" => "sha256:old"))["statusCode"]
      rack_status = Rack::MockRequest.new(
        Prospect::RackApp.new(Fixtures::AppRouter,
                              context_builder: ->(_e) { Fixtures::Context.new(viewer: nil) },
                              on_schema_mismatch: :reject)
      ).post("/rpc/echo/ping", input: '{"who":"x"}', "HTTP_X_PROSPECT_SCHEMA" => "sha256:old").status

      expect(lambda_status).to eq(rack_status)
    end
  end

  # Without this the whole mechanism is decorative: the hash must actually move
  # when the contract does.
  describe "sensitivity" do
    it "changes when a procedure is added" do
      extended = Class.new(Prospect::Router) do
        path :echo
        context Fixtures::Context
        query(:ping, input: Fixtures::Ping, output: Fixtures::Matrix) { Fixtures::MATRIX_VALUE }
        query(:extra, input: Fixtures::Empty, output: Fixtures::Empty) { Fixtures::Empty.new }
      end
      expect(Prospect::IR.extract(extended)["schema_hash"]).not_to eq(server_hash)
    end

    it "does not change when only a handler body changes" do
      # Two routers with identical contracts but different implementations must
      # agree — otherwise every deploy invalidates every client.
      build = lambda do |value|
        Class.new(Prospect::Router) do
          path :echo
          context Fixtures::Context
          query(:ping, input: Fixtures::Ping, output: Fixtures::Matrix) { value }
        end
      end
      a = Prospect::IR.extract(build.call(1))["schema_hash"]
      b = Prospect::IR.extract(build.call(2))["schema_hash"]
      expect(a).to eq(b)
    end
  end
end
