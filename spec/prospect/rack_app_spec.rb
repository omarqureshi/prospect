# frozen_string_literal: true

require "rack"
require "rack/mock"

# The transport is an *event adapter*, not a second dispatcher. These specs
# check what it uniquely owns — path parsing, input extraction, batching,
# context construction — and deliberately do NOT re-test validation, middleware
# or error mapping through HTTP. Those belong to the dispatcher and are covered
# there; retesting them here would be slow and would localise failures badly.
RSpec.describe Prospect::RackApp do
  let(:viewer) { nil }
  let(:app) do
    described_class.new(
      Fixtures::AppRouter,
      context_builder: ->(env) { Fixtures::Context.new(viewer: env["test.viewer"]) }
    )
  end
  let(:mock) { Rack::MockRequest.new(app) }

  def json(response) = JSON.parse(response.body)

  describe "path parsing" do
    it "maps a slash path to a dotted procedure id" do
      res = mock.post("/rpc/echo/ping", input: '{"who":"world"}',
                                        "CONTENT_TYPE" => "application/json")
      expect(res.status).to eq(200)
    end

    # Slash-separated on the wire so API Gateway can route on the unit prefix,
    # dotted as an id. DESIGN.md §6.
    it "rejects a path that is not exactly service/procedure" do
      expect(mock.post("/rpc/echo").status).to eq(404)
      expect(mock.post("/rpc/echo/ping/extra").status).to eq(404)
      expect(mock.post("/rpc/").status).to eq(404)
    end

    it "returns the dispatcher's 404 for an unknown procedure" do
      res = mock.post("/rpc/echo/nope", input: "{}", "CONTENT_TYPE" => "application/json")
      expect(json(res).dig("error", "code")).to eq("unknown_procedure")
    end
  end

  describe "input extraction" do
    it "reads a POST body" do
      res = mock.post("/rpc/echo/ping", input: '{"who":"body"}',
                                        "CONTENT_TYPE" => "application/json")
      expect(res.status).to eq(200)
    end

    # Queries stay GET-able so they can be cached by a CDN.
    it "reads a GET ?input= as urlencoded JSON" do
      res = mock.get("/rpc/echo/ping?input=#{CGI.escape('{"who":"query"}')}")
      expect(res.status).to eq(200)
    end

    it "treats an empty body as an empty input" do
      # Reaches the dispatcher, which then reports the missing required field —
      # rather than the transport crashing on "".
      res = mock.post("/rpc/echo/ping", input: "", "CONTENT_TYPE" => "application/json")
      expect(res.status).to eq(400)
      expect(json(res).dig("error", "errors")).to eq("who" => "is required")
    end

    it "turns malformed JSON into a 400, not a 500" do
      res = mock.post("/rpc/echo/ping", input: "{not json",
                                        "CONTENT_TYPE" => "application/json")
      expect(res.status).to eq(400)
      expect(json(res).dig("error", "code")).to eq("malformed_json")
    end
  end

  describe "responses" do
    it "sets a JSON content type and an accurate content length" do
      res = mock.post("/rpc/echo/ping", input: '{"who":"x"}',
                                        "CONTENT_TYPE" => "application/json")
      expect(res.headers["content-type"]).to eq("application/json")
      expect(res.headers["content-length"].to_i).to eq(res.body.bytesize)
    end

    it "carries the dispatcher's status through" do
      expect(mock.post("/rpc/echo/boom", input: "{}").status).to eq(404)
    end
  end

  describe "context construction" do
    it "builds a context from the Rack env per request" do
      denied = mock.post("/rpc/echo/secret", input: "{}")
      expect(denied.status).to eq(401)

      allowed = mock.post("/rpc/echo/secret", input: "{}", "test.viewer" => "alice")
      expect(allowed.status).to eq(200)
    end

    # Invocation scope, not cold-start scope: a warm container serves many
    # users, so the context must be rebuilt every request. DESIGN.md §6.
    it "rebuilds the context for every request rather than memoizing" do
      built = []
      counting = described_class.new(
        Fixtures::AppRouter,
        context_builder: lambda { |env|
          built << env["test.viewer"]
          Fixtures::Context.new(viewer: env["test.viewer"])
        }
      )
      req = Rack::MockRequest.new(counting)
      req.post("/rpc/echo/secret", input: "{}", "test.viewer" => "alice")
      req.post("/rpc/echo/secret", input: "{}", "test.viewer" => "bob")

      expect(built).to eq(%w[alice bob])
    end
  end

  describe "batching" do
    def batch(calls, env = {})
      mock.post("/rpc?batch=1", { input: JSON.generate(calls),
                                  "CONTENT_TYPE" => "application/json" }.merge(env))
    end

    it "runs several procedures in one request, in order" do
      res = batch([
        { "id" => "echo.ping", "input" => { "who" => "a" } },
        { "id" => "echo.ping", "input" => { "who" => "b" } }
      ])
      rows = json(res)
      expect(rows.length).to eq(2)
      expect(rows.map { |r| r["status"] }).to eq([200, 200])
    end

    # One bad call must not sink the others — the whole point of batching a
    # composite view is that it degrades per-item.
    it "reports per-item status without failing the batch" do
      res = batch([
        { "id" => "echo.ping",  "input" => { "who" => "ok" } },
        { "id" => "echo.boom",  "input" => {} },
        { "id" => "echo.ping",  "input" => {} }
      ])
      expect(res.status).to eq(200)
      rows = json(res)
      expect(rows.map { |r| r["status"] }).to eq([200, 404, 400])
      expect(rows[1].dig("error", "code")).to eq("not_found")
      expect(rows[2].dig("error", "code")).to eq("invalid_input")
    end

    it "applies middleware per item, using one shared context" do
      res = batch([{ "id" => "echo.secret", "input" => {} }])
      expect(json(res).first["status"]).to eq(401)

      allowed = batch([{ "id" => "echo.secret", "input" => {} }], "test.viewer" => "alice")
      expect(json(allowed).first["status"]).to eq(200)
    end
  end

  describe "health" do
    it "lists every registered procedure" do
      body = json(mock.get("/up"))
      expect(body["ok"]).to be(true)
      expect(body["procedures"]).to include("echo.ping", "other.touch")
    end
  end

  # The guarantee that makes local development trustworthy: the transport adds
  # no behaviour of its own, so what works here works through Lambda.
  describe "delegation" do
    it "produces the same body as calling the dispatcher directly" do
      via_http = json(mock.post("/rpc/echo/ping", input: '{"who":"x"}',
                                                  "CONTENT_TYPE" => "application/json"))
      _, direct = Prospect::Dispatcher.new(Fixtures::AppRouter)
                                      .call("echo.ping", { "who" => "x" },
                                            Fixtures::Context.new(viewer: nil))

      expect(via_http).to eq(JSON.parse(JSON.generate(direct)))
    end
  end
end
