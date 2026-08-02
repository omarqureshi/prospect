# frozen_string_literal: true

require "json"

module Prospect
  # Local transport: the WHOLE router in one process, every service mounted.
  # Deployed, those same procedures are spread across N Lambdas — but they share
  # this dispatcher, so behaviour can't drift between the two.
  #
  #   POST /rpc/posts/create        body = input
  #   GET  /rpc/posts/feed?input=…  urlencoded JSON, cacheable
  #   POST /rpc?batch=1             array of { id, input }
  class RackApp
    def initialize(router, context_builder:)
      @dispatcher = Dispatcher.new(router)
      @build_context = context_builder
    end

    attr_reader :dispatcher

    def call(env)
      req = Rack::Request.new(env)
      return json(200, health) if req.path == "/up"
      return batch(req) if req.path == "/rpc" && req.params.key?("batch")

      id = procedure_id(req.path)
      return json(404, { "ok" => false, "error" => { "code" => "not_found" } }) unless id

      status, body = @dispatcher.call(id, input_for(req), @build_context.call(env))
      json(status, body)
    rescue JSON::ParserError => e
      json(400, { "ok" => false,
                  "error" => { "code" => "malformed_json", "detail" => e.message } })
    end

    private

    def health
      { "ok" => true, "procedures" => @dispatcher.procedure_ids.sort }
    end

    # /rpc/posts/feed -> "posts.feed". Slash-separated on the wire so API Gateway
    # can route on the unit prefix; dotted as an id (DESIGN.md §6).
    def procedure_id(path)
      parts = path.delete_prefix("/rpc/").split("/")
      parts.length == 2 ? parts.join(".") : nil
    end

    def input_for(req)
      if req.get?
        raw = req.params["input"]
        raw ? JSON.parse(raw) : {}
      else
        body = req.body.read
        body.empty? ? {} : JSON.parse(body)
      end
    end

    # The client coalesces concurrent queries into one of these, so a bookface
    # post view (posts.get + comments.thread + reactions.mine) is a single round
    # trip. Locally that's one process; deployed it fans out to three Lambdas.
    def batch(req)
      ctx = @build_context.call(req.env)
      calls = JSON.parse(req.body.read)
      results = calls.map do |call|
        status, body = @dispatcher.call(call["id"], call["input"], ctx)
        { "status" => status }.merge(body)
      end
      json(200, results)
    end

    def json(status, body)
      payload = JSON.generate(body)
      [status,
       { "content-type" => "application/json", "content-length" => payload.bytesize.to_s },
       [payload]]
    end
  end
end
