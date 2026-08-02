# frozen_string_literal: true

module Prospect
  # The single dispatcher. Rack, Lambda and the in-process caller are all event
  # *adapters* that decode a request and call this — they must never reimplement
  # validation, middleware or error mapping. That divergence is exactly how
  # "works locally, breaks deployed" gets built in (DESIGN.md §6).
  class Dispatcher
    MIDDLEWARE = {
      authenticated: ->(ctx) { ctx.authenticated! }
    }.freeze

    def initialize(router)
      @router = router
      @by_id  = router.procedures.to_h { |p| [p.id, p] }
    end

    attr_reader :router

    def procedure(id) = @by_id[id]
    def procedure_ids = @by_id.keys

    # Returns [status, body_hash]. Never raises for contract errors — those are
    # part of the response.
    def call(id, raw_input, ctx)
      proc_ = @by_id[id] or return not_found(id)

      input = coerce(proc_, raw_input)
      run_middleware(proc_, ctx)
      output = proc_.handler.call(input, ctx)

      [200, { "ok" => true, "result" => serialize(output) }]
    rescue Error => e
      [e.status, { "ok" => false, "error" => stringify(e.to_h) }]
    end

    private

    def not_found(id)
      [404, { "ok" => false,
              "error" => { "code" => "unknown_procedure", "procedure" => id } }]
    end

    def coerce(proc_, raw)
      input = begin
        proc_.input.from_hash(raw || {})
      rescue StandardError => e
        # Deliberately broad. A missing required prop raises a bare RuntimeError
        # ("Tried to deserialize a required prop from a nil value"), so a narrow
        # rescue list let a malformed request escape as a 500 — found by sending
        # camelCase keys the server doesn't know. Nothing a client sends should
        # ever produce a 500.
        raise InvalidInput.new(errors: { field_from(e.message) => reason(e) })
      end

      validate!(proc_.input, input)
      input
    end

    # `T::Struct.from_hash` does NOT check value types — only `.new` does.
    # Verified: `CreatePostInput.from_hash({"body" => 42})` yields an Integer in
    # a `T.nilable(String)` field, no error. An earlier draft of DESIGN.md §3
    # claimed validation came free with `from_hash`; it does not, and an
    # unvalidated input reaching a handler is how a type error becomes a 500.
    #
    # So walk the declared props and check each against its type. This is the
    # same reflection the IR extractor needs, and it's the concrete case for
    # DESIGN.md §2's rule that the IR must be sufficient to build a validator.
    # Sorbet reports the offending prop inside its message rather than
    # structurally, so recover it to keep errors per-field.
    def field_from(message)
      message[/prop=(\w+)/, 1] || "_"
    end

    def reason(error)
      error.message.include?("required prop") ? "is required" : error.message.lines.first.strip
    end

    def validate!(klass, instance)
      errors = {}
      klass.props.each do |name, rules|
        type = rules[:type_object] || rules[:type]
        next unless type.respond_to?(:valid?)

        value = instance.public_send(name)
        next if type.valid?(value)

        errors[name.to_s] = "expected #{type}, got #{value.class}"
      end
      raise InvalidInput.new(errors: errors) if errors.any?
    end

    def run_middleware(proc_, ctx)
      proc_.middleware.each do |name|
        fn = MIDDLEWARE.fetch(name) { raise ArgumentError, "unknown middleware #{name}" }
        fn.call(ctx)
      end
    end

    # Types with no JSON representation of their own, matched by class NAME so
    # Prospect needs no runtime dependency on date or bigdecimal.
    #
    # BigDecimal is the one that bites: left alone it reaches JSON.generate and
    # emits `0.125e1`, which no client parses. It goes out as a string because
    # JSON numbers are doubles and a decimal that survives a round trip through
    # one is not a decimal — which is also why the IR maps `decimal` to
    # TypeScript `string`.
    ENCODERS = {
      "Date"       => ->(v) { v.iso8601 },
      "DateTime"   => ->(v) { v.to_time.utc.iso8601 },
      "BigDecimal" => ->(v) { v.to_s("F") }
    }.freeze

    def serialize(value)
      case value
      when nil then nil
      when Array then value.map { |v| serialize(v) }
      when Hash then value.to_h { |k, v| [k.to_s, serialize(v)] }
      when Time then value.utc.iso8601   # pinned encoding — bookface DESIGN §6.5
      when Symbol then value.to_s
      else
        if (encode = ENCODERS[value.class.name])
          encode.call(value)
        elsif value.respond_to?(:serialize)
          stringify(value.serialize)
        else
          value
        end
      end
    end

    def stringify(hash)
      hash.to_h { |k, v| [k.to_s, serialize(v)] }
    end
  end
end
