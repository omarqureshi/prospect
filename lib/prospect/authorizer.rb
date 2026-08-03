# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module Prospect
  # A Lambda REQUEST authorizer that supports **optional** authentication.
  #
  # An API Gateway v2 JWT authorizer cannot express this: it rejects a request
  # with no token, and a route without an authorizer receives no verified claims
  # at all. That breaks any procedure which is public but viewer-dependent —
  # bookface's `posts.get` (which computes `editable`) and `reactions.mine` are
  # both public and both need to know who is calling when someone is signed in.
  #
  # This authorizer sees `rawPath`, so it decides per PROCEDURE rather than per
  # route. Two consequences worth knowing:
  #
  #   * Routes can stay greedy (`/rpc/posts/{proxy+}`). The JWT authorizer forced
  #     a split into one route per procedure to carry different auth; this does
  #     not, which keeps the route count down against API Gateway's per-API quota.
  #   * The anonymous list lives here rather than in routing, so changing which
  #     procedures are public is an environment change, not a topology change.
  #
  # Verification covers signature (RS256 against the issuer's JWKS), `exp`,
  # `iss` and `aud`. JWKS is fetched once per execution environment and cached —
  # cold-start scope, not invocation scope.
  class Authorizer
    class Unverified < StandardError; end

    def self.handler(issuer:, audience:, anonymous: [], mount: "/rpc", jwks_url: nil)
      new(issuer: issuer, audience: audience, anonymous: anonymous,
          mount: mount, jwks_url: jwks_url)
    end

    def initialize(issuer:, audience:, anonymous: [], mount: "/rpc", jwks_url: nil)
      @issuer    = issuer.to_s.chomp("/")
      @audience  = Array(audience)
      @anonymous = Array(anonymous).map(&:to_s)
      @mount     = mount
      @jwks_url  = jwks_url || "#{@issuer}/.well-known/jwks.json"
    end

    # SIMPLE response format:
    #   { "isAuthorized" => bool, "context" => { ...claims } }
    # Anything in `context` reaches the function at
    # requestContext.authorizer.lambda.
    def call(event, _lambda_context = nil)
      token = bearer(event)
      procedure = procedure_id(event)

      if token.nil?
        # No token at all. Allowed only where the procedure is declared public.
        return allow({}) if anonymous?(procedure)

        return deny
      end

      begin
        allow(claims_from(token))
      rescue Unverified
        # A present-but-invalid token (expired, wrong audience, bad signature).
        #
        # On a public procedure this is treated as anonymous rather than
        # rejected: someone whose session expired should still see the public
        # feed, and they gain no access by it. On a protected procedure it is a
        # refusal.
        anonymous?(procedure) ? allow({}) : deny
      end
    end

    private

    def allow(context) = { "isAuthorized" => true, "context" => stringify(context) }
    def deny = { "isAuthorized" => false }

    # API Gateway only forwards strings in the authorizer context.
    def stringify(claims)
      claims.to_h { |k, v| [k.to_s, v.is_a?(Array) ? v.join(",") : v.to_s] }
    end

    def anonymous?(procedure) = procedure && @anonymous.include?(procedure)

    # "/rpc/posts/get" -> "posts.get". Deciding here rather than in routing is
    # what lets routes stay greedy.
    def procedure_id(event)
      path = event["rawPath"] || event.dig("requestContext", "http", "path") || ""
      parts = path.delete_prefix("#{@mount}/").split("/")
      parts.length == 2 ? parts.join(".") : nil
    end

    def bearer(event)
      headers = event["headers"] || {}
      raw = headers["authorization"] ||
            headers.find { |k, _| k.to_s.downcase == "authorization" }&.last
      return nil if raw.nil? || raw.empty?

      raw.to_s.sub(/\Abearer\s+/i, "").strip.then { |t| t.empty? ? nil : t }
    end

    def claims_from(token)
      require "jwt"
      payload, = JWT.decode(
        token, nil, true,
        algorithms: ["RS256"],
        jwks: jwks,
        iss: @issuer, verify_iss: true,
        aud: @audience, verify_aud: !@audience.empty?,
        verify_expiration: true
      )
      payload
    rescue Unverified
      raise # an unreachable JWKS is already the right failure
    rescue StandardError => e
      # Broad on purpose: the jwt gem raises several unrelated classes for
      # signature, key-lookup and claim failures, and every one of them means
      # the same thing here — this token is not trustworthy.
      raise Unverified, "#{e.class}: #{e.message}"
    end

    # Cold-start scope: fetched once per execution environment and reused across
    # invocations. Nothing request-specific may be cached here.
    def jwks
      @jwks ||= begin
        body = Net::HTTP.get(URI(@jwks_url))
        JSON.parse(body, symbolize_names: true)
      rescue StandardError => e
        # An unreachable JWKS must not become "everyone is anonymous".
        raise Unverified, "could not fetch JWKS from #{@jwks_url}: #{e.message}"
      end
    end
  end
end
