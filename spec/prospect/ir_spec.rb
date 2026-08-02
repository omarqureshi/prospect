# frozen_string_literal: true

RSpec.describe Prospect::IR do
  subject(:ir) { described_class.extract(Fixtures::AppRouter) }

  # Every emitter reads the IR, so a wrong node here becomes a wrong client in
  # two languages. This is the highest-leverage file in the suite.
  def field(type_name, field_name)
    ir["types"].fetch(type_name)["fields"].find { |f| f["name"] == field_name }.fetch("type")
  end

  describe "scalars" do
    {
      "str"   => "string",
      "int"   => "int",
      "flt"   => "float",
      "at"    => "timestamp",
      "on"    => "date",
      "money" => "decimal"
    }.each do |field_name, scalar|
      it "maps #{field_name} to #{scalar}" do
        expect(field("Matrix", field_name)).to eq("kind" => "scalar", "name" => scalar)
      end
    end
  end

  describe "Sorbet unions that are not wire unions" do
    # Both of these are T::Types::Union underneath. Emitting either as a union
    # would produce `true | false` and `string | null` in TypeScript instead of
    # `boolean` and `string | null` — one wrong, one accidentally right.
    it "collapses T::Boolean to a bool scalar" do
      expect(field("Matrix", "flag")).to eq("kind" => "scalar", "name" => "bool")
    end

    it "collapses T.nilable to optional-of" do
      expect(field("Matrix", "maybe")).to eq(
        "kind" => "optional", "of" => { "kind" => "scalar", "name" => "string" }
      )
    end
  end

  describe "containers" do
    it "represents a typed array as a list" do
      expect(field("Matrix", "list")).to eq(
        "kind" => "list", "of" => { "kind" => "scalar", "name" => "string" }
      )
    end

    it "represents a list of structs as a list of refs" do
      expect(field("Matrix", "refs")).to eq(
        "kind" => "list", "of" => { "kind" => "ref", "name" => "Nested" }
      )
    end

    # THE load-bearing distinction. A map's keys are user data; a struct's are
    # field names. Emitters rename the latter and must never touch the former —
    # bookface's emoji reaction counts are the live case.
    it "represents a typed hash as a map, distinct from a struct" do
      expect(field("Matrix", "lookup")).to eq(
        "kind"  => "map",
        "key"   => { "kind" => "scalar", "name" => "string" },
        "value" => { "kind" => "scalar", "name" => "int" }
      )
    end
  end

  describe "references" do
    it "emits a ref and registers the nested type once" do
      expect(field("Matrix", "nested")).to eq("kind" => "ref", "name" => "Nested")
      expect(ir["types"]).to include("Nested")
    end

    it "represents a T::Enum as its serialized values" do
      expect(field("Matrix", "colour")).to eq("kind" => "enum", "values" => %w[red blue])
    end

    it "terminates on a self-referential type" do
      # Tree contains T::Array[Tree]. Without the placeholder written before the
      # fields are walked, this recurses forever.
      expect(field("Tree", "children")).to eq(
        "kind" => "list", "of" => { "kind" => "ref", "name" => "Tree" }
      )
    end
  end

  describe "strict mode" do
    it "refuses a type it cannot represent, naming it" do
      router = Class.new(Prospect::Router) do
        path :bad
        query(:x, input: Fixtures::Unrepresentable, output: Fixtures::Empty) { Fixtures::Empty.new }
      end

      expect { described_class.extract(router) }
        .to raise_error(Prospect::IR::UnrepresentableType, /Symbol/)
    end
  end

  describe "procedures" do
    def procedure(path) = ir["procedures"].find { |p| p["path"] == path }

    it "records kind, input and output" do
      expect(procedure("echo.ping")).to include(
        "kind"   => "query",
        "input"  => { "kind" => "ref", "name" => "Ping" },
        "output" => { "kind" => "ref", "name" => "Matrix" }
      )
    end

    it "flattens mounted routers" do
      expect(ir["procedures"].map { |p| p["path"] }).to include("echo.ping", "other.touch")
    end

    it "records declared errors with their wire codes" do
      expect(procedure("echo.boom")["errors"]).to eq(
        [{ "name" => "NotFound", "code" => "not_found", "fields" => %w[resource id] }]
      )
    end

    it "leaves errors empty when none are declared" do
      expect(procedure("echo.ping")["errors"]).to be_empty
    end
  end

  describe "schema hash" do
    # The drift detector (DESIGN.md §4). Worthless if it isn't stable, and
    # worthless if it doesn't move.
    it "is stable across extractions" do
      expect(described_class.extract(Fixtures::AppRouter)["schema_hash"])
        .to eq(ir["schema_hash"])
    end

    it "changes when the contract changes" do
      extended = Class.new(Prospect::Router) do
        path :echo
        context Fixtures::Context
        query(:ping, input: Fixtures::Ping, output: Fixtures::Matrix) { Fixtures::MATRIX_VALUE }
        query(:pong, input: Fixtures::Empty, output: Fixtures::Empty) { Fixtures::Empty.new }
      end

      expect(described_class.extract(extended)["schema_hash"]).not_to eq(ir["schema_hash"])
    end

    it "does not hash itself" do
      expect(ir["schema_hash"]).to match(/\Asha256:[0-9a-f]{64}\z/)
    end
  end
end
