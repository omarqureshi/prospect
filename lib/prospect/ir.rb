# frozen_string_literal: true

require "json"
require "digest"

module Prospect
  # Reflects a router into the schema IR — the neutral document every emitter
  # reads (DESIGN.md §4). This is the same walk `Dispatcher#validate!` does over
  # declared props, which is why the "IR must be sufficient to construct a
  # validator" rule holds: one reflection serves both.
  module IR
    SCHEMA_VERSION = "0.1"

    # Ruby class => IR scalar. Deliberately narrow: anything not here is
    # rejected at extraction rather than producing an untypable client.
    SCALARS = {
      "String"     => "string",
      "Integer"    => "int",
      "Float"      => "float",
      "TrueClass"  => "bool",
      "FalseClass" => "bool",
      "Time"       => "timestamp",
      # Timestamps arrive from ORMs as DateTime/Date, never Time — see
      # bookface-rpc DESIGN §6. Accepting the family here is what stops every
      # app writing `.to_time` at its presenter boundary.
      "DateTime"   => "timestamp",
      "Date"       => "date",
      "BigDecimal" => "decimal",
      "NilClass"   => "null"
    }.freeze

    class UnrepresentableType < StandardError; end

    class << self
      def extract(router)
        types = {}
        procedures = router.procedures.map do |p|
          {
            "path"   => p.id,
            "kind"   => p.kind.to_s,
            "input"  => type_node(p.input, types),
            "output" => type_node(p.output, types),
            "errors" => p.errors.map { |e| error_node(e) }
          }
        end

        doc = {
          "prospect_schema" => SCHEMA_VERSION,
          "types"           => types,
          "procedures"      => procedures.sort_by { |p| p["path"] }
        }
        # Hash of content only, so it's stable across runs — the drift detector
        # (DESIGN.md §4). Inserted after hashing so it doesn't hash itself.
        doc.merge("schema_hash" => "sha256:#{Digest::SHA256.hexdigest(JSON.generate(doc))}")
      end

      def write(router, path)
        File.write(path, JSON.pretty_generate(extract(router)) + "\n")
      end

      private

      def error_node(klass)
        { "name"   => klass.name.split("::").last,
          "code"   => klass.code,
          "fields" => klass.fields.keys.map(&:to_s) }
      end

      # Registers a T::Struct in `types` and returns a ref to it.
      def type_node(klass, types)
        name = klass.name.split("::").last
        unless types.key?(name)
          types[name] = { "kind" => "struct", "fields" => [] } # placeholder breaks cycles
          types[name]["fields"] = klass.props.map do |prop, rules|
            node = from_type_object(rules[:type_object] || rules[:type], types)
            field = { "name" => prop.to_s, "type" => node }
            field["default"] = true if rules.key?(:default) || rules[:fully_optional]
            field
          end
        end
        { "kind" => "ref", "name" => name }
      end

      def from_type_object(type, types)
        case type
        when T::Types::Union            then union(type, types)
        when T::Types::TypedArray       then { "kind" => "list", "of" => from_type_object(type.type, types) }
        when T::Types::TypedHash        then map_node(type, types)
        when T::Types::Simple           then simple(type.raw_type, types)
        else
          raise UnrepresentableType, "cannot represent #{type.inspect} in the IR"
        end
      end

      def simple(raw, types)
        if (scalar = SCALARS[raw.name])
          { "kind" => "scalar", "name" => scalar }
        elsif raw.respond_to?(:props)          # a nested T::Struct
          type_node(raw, types)
        elsif raw < T::Enum
          { "kind" => "enum", "values" => raw.values.map(&:serialize).map(&:to_s) }
        else
          raise UnrepresentableType, "#{raw} has no IR representation — strict mode"
        end
      end

      # T.nilable(X) is a Union of X and NilClass; T::Boolean is a Union of
      # TrueClass and FalseClass. Both are unions in Sorbet, neither is a union
      # on the wire.
      def union(type, types)
        members = type.types.map { |t| t.is_a?(T::Types::Simple) ? t.raw_type.name : t }
        return { "kind" => "scalar", "name" => "bool" } if members.sort == %w[FalseClass TrueClass]

        non_nil = type.types.reject { |t| t.is_a?(T::Types::Simple) && t.raw_type == NilClass }
        if non_nil.length == type.types.length
          { "kind" => "union", "of" => non_nil.map { |t| from_type_object(t, types) } }
        elsif non_nil.length == 1
          { "kind" => "optional", "of" => from_type_object(non_nil.first, types) }
        else
          { "kind" => "optional",
            "of" => { "kind" => "union", "of" => non_nil.map { |t| from_type_object(t, types) } } }
        end
      end

      # A map's keys are DATA, not field names. Emitters must never rename them —
      # this node is what tells them apart from a struct (DESIGN.md §7).
      def map_node(type, types)
        { "kind" => "map",
          "key"   => from_type_object(type.keys, types),
          "value" => from_type_object(type.values, types) }
      end
    end
  end
end
