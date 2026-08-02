# frozen_string_literal: true


require "rack"
require "rack/mock"
# Hermetic: an API Gateway event is just a Hash, so none of this needs AWS,
# Docker or a deploy. Same division as the Rack specs — this covers what the
# adapter uniquely owns (payload decoding, unit scoping, response shape) and
# leaves validation and middleware to the dispatcher specs.
RSpec.describe Prospect::Lambda do
  let(:builder) { ->(event) { Fixtures::Context.new(viewer: event["test.viewer"]) } }
  let(:handler) { described_class.handler(Fixtures::AppRouter, context_builder: builder) }

  # API Gateway HTTP API payload format 2.0, which Function URLs also speak.
  def event(path, method: "POST", body: nil, query: nil, base64: false, **extra)
    {
      "version" => "2.0",
      "rawPath" => path,
      "headers" => { "content-type" => "application/json" },
      "queryStringParameters" => query,
      "requestContext" => { "http" => { "method" => method, "path" => path } },
      "body" => body,
      "isBase64Encoded" => base64
    }.merge(extra)
  end

  def body_of(response) = JSON.parse(response["body"])

  describe "response shape" do
    it "returns the statusCode/headers/body triple API Gateway expects" do
      res = handler.call(event("/rpc/echo/ping", body: '{"who":"x"}'))
      expect(res).to include("statusCode" => 200)
      expect(res["headers"]).to eq("content-type" => "application/json")
      expect(res["body"]).to be_a(String)
    end

    it "carries a dispatcher error status through" do
      expect(handler.call(event("/rpc/echo/boom", body: "{}"))["statusCode"]).to eq(404)
    end
  end

  describe "payload decoding" do
    it "reads a POST body" do
      res = handler.call(event("/rpc/echo/ping", body: '{"who":"body"}'))
      expect(res["statusCode"]).to eq(200)
    end

    it "reads a GET input from queryStringParameters" do
      res = handler.call(event("/rpc/echo/ping", method: "GET",
                                                 query: { "input" => '{"who":"q"}' }))
      expect(res["statusCode"]).to eq(200)
    end

    # API Gateway base64-encodes bodies it considers binary. Missing this makes
    # requests fail only for certain content types — the worst kind of bug.
    it "decodes a base64-encoded body" do
      res = handler.call(event("/rpc/echo/ping",
                               body: ['{"who":"b64"}'].pack("m0"), base64: true))
      expect(res["statusCode"]).to eq(200)
    end

    it "treats a nil or empty body as empty input" do
      expect(handler.call(event("/rpc/echo/ping", body: nil))["statusCode"]).to eq(400)
      expect(handler.call(event("/rpc/echo/ping", body: ""))["statusCode"]).to eq(400)
      expect(body_of(handler.call(event("/rpc/echo/ping"))).dig("error", "errors"))
        .to eq("who" => "is required")
    end

    it "turns malformed JSON into a 400, not a crash" do
      res = handler.call(event("/rpc/echo/ping", body: "{nope"))
      expect(res["statusCode"]).to eq(400)
      expect(body_of(res).dig("error", "code")).to eq("malformed_json")
    end

    it "falls back to requestContext path when rawPath is absent" do
      e = event("/rpc/echo/ping", body: '{"who":"x"}')
      e.delete("rawPath")
      expect(handler.call(e)["statusCode"]).to eq(200)
    end
  end

  describe "unit scoping" do
    let(:handler) do
      described_class.handler(Fixtures::AppRouter, unit: "echo", context_builder: builder)
    end

    it "serves procedures in its own unit" do
      expect(handler.call(event("/rpc/echo/ping", body: '{"who":"x"}'))["statusCode"]).to eq(200)
    end

    # Defence in depth: API Gateway shouldn't route another service's traffic
    # here, but if it ever does, this function must not serve it. The per-service
    # IAM boundary is exactly what a misroute would bypass.
    it "refuses a procedure belonging to another unit" do
      res = handler.call(event("/rpc/other/touch", body: "{}"))
      expect(res["statusCode"]).to eq(404)
      expect(body_of(res).dig("error", "code")).to eq("not_in_unit")
    end

    it "refuses out-of-unit calls inside a batch too" do
      res = handler.call(event("/rpc", query: { "batch" => "1" }, body: JSON.generate([
        { "id" => "echo.ping", "input" => { "who" => "x" } },
        { "id" => "other.touch", "input" => {} }
      ])))
      expect(body_of(res).map { |r| r["status"] }).to eq([200, 404])
    end

    it "reports only its own procedures on /up" do
      body = body_of(handler.call(event("/rpc/up", method: "GET")))
      expect(body["procedures"]).to eq(%w[echo.boom echo.explode echo.ping echo.secret])
      expect(body["unit"]).to eq("echo")
    end

    it "serves everything when no unit is set" do
      unscoped = described_class.handler(Fixtures::AppRouter, context_builder: builder)
      expect(unscoped.call(event("/rpc/other/touch", body: "{}"))["statusCode"]).to eq(200)
    end
  end

  describe "routing" do
    it "rejects a path that is not service/procedure" do
      expect(handler.call(event("/rpc/echo"))["statusCode"]).to eq(404)
      expect(handler.call(event("/rpc/echo/ping/extra"))["statusCode"]).to eq(404)
    end

    it "returns the dispatcher's error for an unknown procedure" do
      res = handler.call(event("/rpc/echo/nope", body: "{}"))
      expect(body_of(res).dig("error", "code")).to eq("unknown_procedure")
    end
  end

  describe "batching" do
    it "runs a batch and reports per-item status" do
      res = handler.call(event("/rpc", query: { "batch" => "1" }, body: JSON.generate([
        { "id" => "echo.ping", "input" => { "who" => "a" } },
        { "id" => "echo.boom", "input" => {} },
        { "id" => "echo.ping", "input" => {} }
      ])))
      expect(res["statusCode"]).to eq(200)
      expect(body_of(res).map { |r| r["status"] }).to eq([200, 404, 400])
    end
  end

  describe "context" do
    it "builds a context from the event, per invocation" do
      expect(handler.call(event("/rpc/echo/secret", body: "{}"))["statusCode"]).to eq(401)
      expect(handler.call(event("/rpc/echo/secret", body: "{}",
                                "test.viewer" => "alice"))["statusCode"]).to eq(200)
    end

    # A warm execution environment serves many users. Memoizing here would leak
    # one caller's identity into the next invocation — the classic Lambda bug
    # (DESIGN.md §6).
    it "rebuilds the context for every invocation" do
      seen = []
      h = described_class.handler(
        Fixtures::AppRouter,
        context_builder: lambda { |e|
          seen << e["test.viewer"]
          Fixtures::Context.new(viewer: e["test.viewer"])
        }
      )
      h.call(event("/rpc/echo/secret", body: "{}", "test.viewer" => "alice"))
      h.call(event("/rpc/echo/secret", body: "{}", "test.viewer" => "bob"))
      expect(seen).to eq(%w[alice bob])
    end
  end

  # The guarantee that makes the local Rack loop trustworthy: both transports
  # are adapters over one dispatcher, so a given input produces one answer.
  describe "parity with the Rack transport" do
    it "produces the same body as an equivalent Rack request" do
      lambda_body = body_of(handler.call(event("/rpc/echo/ping", body: '{"who":"x"}')))

      rack = Prospect::RackApp.new(Fixtures::AppRouter, context_builder: ->(_env) {
        Fixtures::Context.new(viewer: nil)
      })
      rack_res = Rack::MockRequest.new(rack).post(
        "/rpc/echo/ping", input: '{"who":"x"}', "CONTENT_TYPE" => "application/json"
      )

      expect(lambda_body).to eq(JSON.parse(rack_res.body))
    end

    it "agrees with Rack on errors too" do
      lambda_body = body_of(handler.call(event("/rpc/echo/ping", body: '{"who":42}')))
      rack = Prospect::RackApp.new(Fixtures::AppRouter, context_builder: ->(_e) {
        Fixtures::Context.new(viewer: nil)
      })
      rack_body = JSON.parse(Rack::MockRequest.new(rack).post(
        "/rpc/echo/ping", input: '{"who":42}', "CONTENT_TYPE" => "application/json"
      ).body)

      expect(lambda_body).to eq(rack_body)
    end
  end
end
