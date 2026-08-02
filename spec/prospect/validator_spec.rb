# frozen_string_literal: true

RSpec.describe "input validation and dispatch" do
  let(:dispatcher) { Prospect::Dispatcher.new(Fixtures::AppRouter) }
  let(:anon)       { Fixtures::Context.new(viewer: nil) }
  let(:signed_in)  { Fixtures::Context.new(viewer: "alice") }

  def call(id, input, ctx = anon) = dispatcher.call(id, input, ctx)

  describe "accepting good input" do
    it "coerces and dispatches" do
      status, body = call("echo.ping", { "who" => "world" })
      expect(status).to eq(200)
      expect(body["ok"]).to be(true)
    end

    it "applies declared defaults for omitted fields" do
      status, = call("echo.ping", { "who" => "world" }) # `loud` omitted
      expect(status).to eq(200)
    end
  end

  describe "rejecting bad input" do
    it "reports a wrong type per field" do
      status, body = call("echo.ping", { "who" => 42 })
      expect(status).to eq(400)
      expect(body.dig("error", "code")).to eq("invalid_input")
      expect(body.dig("error", "errors")).to eq("who" => "expected String, got Integer")
    end

    it "reports a missing required field by name" do
      status, body = call("echo.ping", {})
      expect(status).to eq(400)
      expect(body.dig("error", "errors")).to eq("who" => "is required")
    end

    # Regression: this exact shape escaped as a 500. The UI sent camelCase keys,
    # `who` arrived nil, and from_hash raised a bare RuntimeError that the
    # dispatcher's narrow rescue list didn't catch.
    it "treats unrecognised keys as a missing field, not a crash" do
      status, body = call("echo.ping", { "whoWho" => "world" })
      expect(status).to eq(400)
      expect(body.dig("error", "errors")).to eq("who" => "is required")
    end

    # The invariant that matters more than any single case above.
    it "never produces a 5xx for any client input" do
      [
        {}, nil,
        { "who" => nil }, { "who" => 42 }, { "who" => [] }, { "who" => { "a" => 1 } },
        { "who" => "ok", "loud" => "not a bool" },
        { "unknown" => 1 }, { "who" => "ok", "extra" => "ignored" }
      ].each do |input|
        status, = call("echo.ping", input)
        expect(status).to be < 500, "#{input.inspect} produced #{status}"
      end
    end
  end

  describe "errors declared in the contract" do
    it "maps a declared error to its own status and code" do
      status, body = call("echo.boom", {})
      expect(status).to eq(404)
      expect(body["error"]).to eq(
        "code" => "not_found", "resource" => "thing", "id" => "1"
      )
    end

    it "returns 404 for an unknown procedure" do
      status, body = call("echo.nope", {})
      expect(status).to eq(404)
      expect(body.dig("error", "code")).to eq("unknown_procedure")
    end

    # A handler bug is NOT a contract error and must not be dressed up as one —
    # swallowing it into a 4xx would hide real failures.
    it "lets an unexpected handler exception propagate" do
      expect { call("echo.explode", {}) }.to raise_error(RuntimeError, /blew up/)
    end
  end

  describe "middleware" do
    it "rejects an anonymous caller with 401" do
      status, body = call("echo.secret", {}, anon)
      expect(status).to eq(401)
      expect(body.dig("error", "code")).to eq("unauthorized")
    end

    it "admits a signed-in caller" do
      status, = call("echo.secret", {}, signed_in)
      expect(status).to eq(200)
    end

    it "leaves unguarded procedures open" do
      status, = call("echo.ping", { "who" => "x" }, anon)
      expect(status).to eq(200)
    end

    it "runs before the handler, not after" do
      # If ordering were reversed, the handler would run for anonymous callers
      # and any side effect would already have happened.
      expect(dispatcher.procedure("echo.secret").middleware).to eq([:authenticated])
    end
  end

  describe "output serialization" do
    subject(:result) { call("echo.ping", { "who" => "x" }).last["result"] }

    it "pins timestamps to RFC 3339 UTC" do
      expect(result["at"]).to eq("2026-01-02T03:04:05Z")
    end

    it "leaves map keys untouched" do
      expect(result["lookup"]).to eq("👍" => 2)
    end

    it "encodes dates as ISO 8601" do
      expect(result["on"]).to eq("2026-01-02")
    end

    # Regression: BigDecimal reached JSON.generate raw and emitted `0.125e1`.
    # A string, not a number — JSON numbers are doubles, and a decimal that
    # survives a round trip through one is not a decimal.
    it "encodes decimals as plain strings" do
      expect(result["money"]).to eq("1.25")
    end

    it "produces output that is valid JSON with no Ruby objects left in it" do
      round_tripped = JSON.parse(JSON.generate(result))
      expect(round_tripped).to eq(result)
    end

    it "serializes nested structs" do
      expect(result["nested"]).to eq("label" => "deep")
    end

    it "does not rename struct fields — that is the client's job" do
      expect(result).to have_key("two_words")
    end
  end

  # Not testing Sorbet — pinning behaviour we depend on. `from_hash` silently
  # skipping validation is why Dispatcher#validate! exists at all; if a future
  # sorbet-runtime starts checking, these fail and we can delete code.
  describe "sorbet-runtime assumptions" do
    it "from_hash does NOT check value types" do
      expect(Fixtures::Ping.from_hash("who" => 42).who).to eq(42)
    end

    it ".new DOES check value types" do
      expect { Fixtures::Ping.new(who: 42) }.to raise_error(TypeError)
    end

    it "from_hash raises a bare RuntimeError for a missing required prop" do
      expect { Fixtures::Ping.from_hash({}) }
        .to raise_error(RuntimeError, /required prop/)
    end

    it "from_hash ignores unknown keys" do
      expect(Fixtures::Ping.from_hash("who" => "x", "nope" => 1).who).to eq("x")
    end
  end
end
