# frozen_string_literal: true

require "jwt"
require "openssl"
require "base64"

# Real RS256 signing against a real JWKS — a generated key pair, not stubs.
# This is auth code; asserting on a mocked verifier would test nothing.
RSpec.describe Prospect::Authorizer do
  ISSUER   = "https://cognito-idp.eu-west-2.amazonaws.com/pool"
  AUDIENCE = "client-id"

  let(:key) { @key }
  before(:all) { @key = OpenSSL::PKey::RSA.generate(2048) }

  def jwks
    jwk = JWT::JWK.new(@key, { kid: "test-key", use: "sig", alg: "RS256" })
    JSON.parse(JSON.generate({ keys: [jwk.export] }), symbolize_names: true)
  end

  def token(claims = {}, signing_key: @key)
    payload = { "sub" => "user-alice", "email" => "alice@example.com",
                "iss" => ISSUER, "aud" => AUDIENCE,
                "exp" => Time.now.to_i + 3600 }.merge(claims)
    JWT.encode(payload, signing_key, "RS256", { kid: "test-key" })
  end

  def authorizer(anonymous: [])
    described_class.handler(issuer: ISSUER, audience: [AUDIENCE], anonymous: anonymous)
                   .tap { |a| a.instance_variable_set(:@jwks, jwks) }
  end

  def event(path, headers = {})
    { "rawPath" => path, "headers" => headers,
      "requestContext" => { "http" => { "method" => "POST", "path" => path } } }
  end

  def auth_header(t) = { "authorization" => "Bearer #{t}" }

  describe "a valid token" do
    it "authorises and passes the claims through" do
      res = authorizer.call(event("/rpc/posts/create", auth_header(token)))
      expect(res["isAuthorized"]).to be(true)
      expect(res["context"]).to include("sub" => "user-alice", "email" => "alice@example.com")
    end

    it "accepts a bare token without the Bearer prefix" do
      res = authorizer.call(event("/rpc/posts/create", "authorization" => token))
      expect(res["isAuthorized"]).to be(true)
    end

    it "reads the header case-insensitively" do
      res = authorizer.call(event("/rpc/posts/create", "Authorization" => "Bearer #{token}"))
      expect(res["isAuthorized"]).to be(true)
    end

    # API Gateway only forwards strings in the authorizer context.
    it "stringifies claim values" do
      res = authorizer.call(event("/rpc/posts/create", auth_header(token({ "custom" => 42 }))))
      expect(res["context"]["custom"]).to eq("42")
    end
  end

  # The whole reason this exists: a JWT authorizer cannot do this.
  describe "optional auth" do
    it "allows an anonymous caller on a public procedure, with empty context" do
      res = authorizer(anonymous: %w[posts.feed]).call(event("/rpc/posts/feed"))
      expect(res).to eq("isAuthorized" => true, "context" => {})
    end

    it "still identifies a signed-in caller on that same public procedure" do
      res = authorizer(anonymous: %w[posts.feed])
            .call(event("/rpc/posts/feed", auth_header(token)))
      expect(res["context"]).to include("sub" => "user-alice")
    end

    it "refuses an anonymous caller on a protected procedure" do
      res = authorizer(anonymous: %w[posts.feed]).call(event("/rpc/posts/create"))
      expect(res).to eq("isAuthorized" => false)
    end
  end

  describe "rejecting bad tokens" do
    it "refuses a token signed by the wrong key" do
      other = OpenSSL::PKey::RSA.generate(2048)
      res = authorizer.call(event("/rpc/posts/create", auth_header(token({}, signing_key: other))))
      expect(res["isAuthorized"]).to be(false)
    end

    it "refuses an expired token" do
      res = authorizer.call(event("/rpc/posts/create",
                                  auth_header(token({ "exp" => Time.now.to_i - 60 }))))
      expect(res["isAuthorized"]).to be(false)
    end

    it "refuses a token for another audience" do
      res = authorizer.call(event("/rpc/posts/create", auth_header(token({ "aud" => "someone-else" }))))
      expect(res["isAuthorized"]).to be(false)
    end

    it "refuses a token from another issuer" do
      res = authorizer.call(event("/rpc/posts/create", auth_header(token({ "iss" => "https://evil" }))))
      expect(res["isAuthorized"]).to be(false)
    end

    it "refuses garbage" do
      res = authorizer.call(event("/rpc/posts/create", auth_header("not-a-jwt")))
      expect(res["isAuthorized"]).to be(false)
    end

    # An expired session should not black out the public feed — and grants no
    # access, since the caller is treated as anonymous rather than as themselves.
    it "treats an invalid token as anonymous on a public procedure" do
      res = authorizer(anonymous: %w[posts.feed])
            .call(event("/rpc/posts/feed", auth_header(token({ "exp" => Time.now.to_i - 60 }))))
      expect(res).to eq("isAuthorized" => true, "context" => {})
    end
  end

  describe "routing" do
    # Deciding from rawPath rather than routeKey is what lets routes stay greedy
    # instead of splitting one per procedure.
    it "derives the procedure from the path, whatever the route granularity" do
      a = authorizer(anonymous: %w[reactions.mine])
      expect(a.call(event("/rpc/reactions/mine"))["isAuthorized"]).to be(true)
      expect(a.call(event("/rpc/reactions/toggle"))["isAuthorized"]).to be(false)
    end

    it "refuses a path it cannot resolve to a procedure" do
      expect(authorizer(anonymous: %w[posts.feed]).call(event("/rpc/posts"))["isAuthorized"])
        .to be(false)
    end
  end

  describe "an unreachable JWKS" do
    # Must not degrade into "everyone is anonymous".
    it "refuses rather than failing open" do
      a = described_class.handler(issuer: "https://127.0.0.1:1", audience: [AUDIENCE],
                                  anonymous: [])
      res = a.call(event("/rpc/posts/create", auth_header(token)))
      expect(res["isAuthorized"]).to be(false)
    end
  end
end
