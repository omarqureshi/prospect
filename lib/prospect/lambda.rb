# frozen_string_literal: true

require "json"

module Prospect
  # Lambda event adapter. Decodes an API Gateway v2 / Function URL payload and
  # delegates to the SAME dispatcher the Rack transport uses.
  #
  # It is an adapter, not a second implementation: validation, middleware and
  # error mapping live in Dispatcher, and duplicating any of them here is how
  # "works locally, breaks deployed" gets built in (DESIGN.md §6).
  #
  #   # handler.rb, generated per unit
  #   require_relative "vendor/bundle/bundler/setup"   # never `bundle exec`
  #   require_relative "boot"
  #   HANDLER = Prospect::Lambda.handler(
  #     AppRouter, unit: "users",
  #     context_builder: MyApp::Context.method(:from_event)
  #   )
  #   def handle(event:, context:) = HANDLER.call(event, context)
  class Lambda
    def self.handler(router, unit: nil, context_builder:, **opts)
      new(router, unit: unit, context_builder: context_builder, **opts)
    end

    def initialize(router, context_builder:, unit: nil, on_schema_mismatch: :warn)
      @dispatcher = Dispatcher.new(router, on_schema_mismatch: on_schema_mismatch)
      @unit = unit&.to_s
      @build_context = context_builder
    end

    attr_reader :dispatcher, :unit

    def call(event, _lambda_context = nil)
      path = event["rawPath"] || event.dig("requestContext", "http", "path") || ""
      return respond(200, health) if path.end_with?("/up")

      if (mismatch = @dispatcher.check_schema(header(event, Dispatcher::SCHEMA_HEADER)))
        return respond(*mismatch)
      end

      ctx = @build_context.call(event)
      return batch(event, ctx) if batch?(event, path)

      id = procedure_id(path)
      return respond(404, error("not_found")) unless id
      return respond(404, error("not_in_unit", "procedure" => id)) unless serves?(id)

      status, body = @dispatcher.call(id, input_for(event), ctx)
      respond(status, body)
    rescue JSON::ParserError => e
      respond(400, error("malformed_json", "detail" => e.message))
    end

    private

    # API Gateway lower-cases header names, but a Function URL invoked directly
    # in a test may not.
    def header(event, name)
      headers = event["headers"] || {}
      headers[name] || headers.find { |k, _| k.to_s.downcase == name }&.last
    end

    def health
      { "ok" => true, "unit" => @unit, "schema" => @dispatcher.schema_hash,
        "procedures" => @dispatcher.procedure_ids.select { |id| serves?(id) }.sort }
    end

    # Defence in depth. API Gateway routes `/rpc/users/{proxy+}` to the users
    # function, but if a route is ever misconfigured this function must not
    # quietly serve another service's procedures — the per-service IAM boundary
    # would be exactly the thing bypassed.
    def serves?(id)
      return true if @unit.nil?

      id == @unit || id.start_with?("#{@unit}.")
    end

    def procedure_id(path)
      parts = path.delete_prefix("/rpc/").split("/")
      parts.length == 2 ? parts.join(".") : nil
    end

    def batch?(event, path)
      path.delete_suffix("/") .end_with?("/rpc") &&
        event.dig("queryStringParameters", "batch")
    end

    def body_of(event)
      raw = event["body"]
      return nil if raw.nil? || raw.empty?

      # unpack1("m") rather than Base64.decode64: base64 stopped being a default
      # gem in Ruby 3.4, and a framework should not add a dependency for one call.
      event["isBase64Encoded"] ? raw.unpack1("m") : raw
    end

    def input_for(event)
      method = event.dig("requestContext", "http", "method").to_s.upcase
      if method == "GET"
        raw = event.dig("queryStringParameters", "input")
        raw ? JSON.parse(raw) : {}
      else
        raw = body_of(event)
        raw ? JSON.parse(raw) : {}
      end
    end

    def batch(event, ctx)
      calls = JSON.parse(body_of(event) || "[]")
      rows = calls.map do |call|
        id = call["id"]
        unless serves?(id)
          next({ "status" => 404 }.merge(error("not_in_unit", "procedure" => id)))
        end

        status, body = @dispatcher.call(id, call["input"], ctx)
        { "status" => status }.merge(body)
      end
      respond(200, rows)
    end

    def error(code, extra = {})
      { "ok" => false, "error" => { "code" => code }.merge(extra) }
    end

    def respond(status, body)
      { "statusCode" => status,
        "headers" => { "content-type" => "application/json" },
        "body" => JSON.generate(body) }
    end
  end
end
