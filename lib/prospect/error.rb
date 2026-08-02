# frozen_string_literal: true

module Prospect
  # Raised for router DSL misuse, always at load time. Distinct from Error,
  # which is part of an app's wire contract — this one never reaches a client.
  class DefinitionError < StandardError; end

  # Base class for declared, typed errors.
  #
  # IMPLEMENTATION NOTE — these are deliberately NOT `T::Struct`s, even though
  # every other schema type is. A class cannot inherit from both `Exception` and
  # `T::Struct`, and errors have to be raisable to be usable:
  #
  #     raise Errors::NotFound.new(resource: "post", id: id)
  #
  # So `Error` reimplements just enough of the `const` DSL to look the same at
  # the authoring site and to stay reflectable for the IR. The alternative —
  # errors as plain structs wrapped in a generic `raise Prospect::Fault.new(s)` —
  # reads worse everywhere it's used, which is most places.
  class Error < StandardError
    class << self
      def const(name, type)
        fields[name] = type
        attr_reader(name)
      end

      def fields
        @fields ||= superclass.respond_to?(:fields) ? superclass.fields.dup : {}
      end

      # Wire discriminator: "not_found", "validation_failed", …
      def code
        @code ||= name.to_s.split("::").last
                      .gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase
      end
    end

    def initialize(**attrs)
      unknown = attrs.keys - self.class.fields.keys
      raise ArgumentError, "unknown error fields: #{unknown.join(', ')}" if unknown.any?

      attrs.each { |k, v| instance_variable_set(:"@#{k}", v) }
      super(self.class.code)
    end

    def to_h
      { code: self.class.code }.merge(
        self.class.fields.keys.to_h { |f| [f, public_send(f)] }
      )
    end

    # HTTP status for the Rack/Lambda transports. Overridable per error class.
    def status = 422
  end

  # Built-ins every app gets. bookface-rpc redefines NotFound/Forbidden/etc. of
  # its own today — an open question (its DESIGN §6.4) is how many of these
  # Prospect should own so apps stop reinventing them.
  class Unauthorized < Error
    def status = 401
  end

  class NotFound < Error
    const :resource, String
    const :id, String
    def status = 404
  end

  class Forbidden < Error
    const :action, String
    const :resource, String
    def status = 403
  end

  # Raised by the dispatcher when input doesn't match the declared type, so a
  # malformed request is a contract error rather than a 500. Carries per-field
  # detail: { "body" => "expected String, got Integer" }.
  class InvalidInput < Error
    const :errors, Hash
    def status = 400
  end
end
