# frozen_string_literal: true

RSpec.describe Prospect::Emit::TypeScript do
  let(:ir)      { Prospect::IR.extract(Fixtures::AppRouter) }
  let(:emitted) { described_class.call(ir) }
  let(:golden)  { File.expand_path("../golden/schema.ts", __dir__) }

  describe "the golden file" do
    # Regenerate with:  UPDATE_GOLDEN=1 bundle exec rspec
    #
    # A golden proves the output didn't change. It does NOT prove the output is
    # correct — spec/golden/usage.ts does that, by compiling against these types
    # with @ts-expect-error assertions.
    it "matches the committed output" do
      if ENV["UPDATE_GOLDEN"]
        File.write(golden, emitted)
        skip "golden regenerated"
      end

      expect(emitted).to eq(File.read(golden)),
                         "emitted TypeScript changed. Review the diff, then " \
                         "regenerate with UPDATE_GOLDEN=1 bundle exec rspec"
    end
  end

  # Targeted assertions on the load-bearing bits. A golden tells you *something*
  # moved; these tell you *what* broke.
  describe "type mapping" do
    it "emits a map as an index signature so its keys stay open" do
      expect(emitted).to include("lookup: Record<string, number>")
    end

    it "emits T::Boolean as boolean, not a union" do
      expect(emitted).to include("flag: boolean")
    end

    it "emits nilable as `| null` and defaulted as optional" do
      expect(emitted).to include("maybe?: string | null")
      expect(emitted).to include("withDefault?: string")
    end

    it "emits an enum as a literal union" do
      expect(emitted).to include(%(colour: "red" | "blue"))
    end

    it "emits timestamp, date and decimal as strings" do
      expect(emitted).to include("at: string", "on: string", "money: string")
    end

    it "camelCases field names" do
      expect(emitted).to include("twoWords: string")
    end
  end

  describe "the schema hash" do
    it "publishes the contract fingerprint for the client to send" do
      expect(emitted).to include(%(export const SCHEMA_HASH = "#{ir['schema_hash']}"))
    end
  end

  describe "the wire tables" do
    it "records renames only for fields that actually differ" do
      expect(emitted).to include(%(Matrix: { withDefault: "with_default", twoWords: "two_words" }))
    end

    # The reason a generic deep-camelize is wrong: `lookup`'s keys are data.
    # Absent from both tables means the client never touches them.
    it "omits map fields from the rename and recursion tables" do
      tables = emitted[/WIRE_FIELDS.*?\n}\n.*?WIRE_NESTED.*?\n}\n/m]
      expect(tables).not_to include("lookup")
    end

    it "lists nested struct fields for recursion" do
      expect(emitted).to include(%(Matrix: { refs: "Nested", nested: "Nested", tree: "Tree" }))
    end

    it "maps every procedure to its input and output types" do
      expect(emitted).to include(%("echo.ping": { input: "Ping", output: "Matrix" }))
    end

    it "maps error codes to their interfaces" do
      expect(emitted).to include(%(not_found: "NotFound"))
    end
  end

  describe "procedures" do
    it "carries the query/mutation distinction into the type" do
      expect(emitted).to include(%("echo.ping": { kind: "query"))
      expect(emitted).to include(%("other.touch": { kind: "mutation"))
    end

    it "types an undeclared error as never" do
      expect(emitted).to include(%("echo.ping": { kind: "query"; input: Ping; output: Matrix; error: never }))
    end

    it "unions declared errors" do
      expect(emitted).to include("error: NotFound }")
    end
  end

  it "emits no client code — types only" do
    expect(emitted).not_to include("fetch(", "async ", "function ")
  end
end
