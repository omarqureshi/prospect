# frozen_string_literal: true

require "open3"

# The check most codegen projects skip, and the reason they ship broken types:
# a golden file only proves the output is *unchanged*, and a string assertion
# only proves a substring is present. Neither notices that the emitted
# TypeScript is semantically wrong. The compiler does.
#
# spec/golden/usage.ts consumes these types with `@ts-expect-error` assertions,
# so this run checks both directions — valid uses must compile, invalid ones
# must not. An unused `@ts-expect-error` is itself a compile error, which is
# what gives the negative assertions teeth.
RSpec.describe "the emitted TypeScript compiles" do
  root = File.expand_path("../..", __dir__)
  tsc  = File.join(root, "node_modules", ".bin", "tsc")

  # Skipping loudly, not silently: a green suite that quietly never ran the
  # typecheck is worse than a red one.
  if !File.executable?(tsc)
    it "typechecks the golden output" do
      skip "typescript not installed — run `npm install` in #{root}"
    end
  else
    it "typechecks the golden output against usage.ts" do
      out, status = Open3.capture2e(tsc, "-p", File.join(root, "spec/golden"), chdir: root)
      expect(status).to be_success, "tsc failed:\n#{out}"
    end

    # The golden is what tsc reads, so if it has drifted from the emitter the
    # typecheck above is checking a stale file. This ties the two together.
    it "typechecks output that is current with the emitter" do
      emitted = Prospect::Emit::TypeScript.call(Prospect::IR.extract(Fixtures::AppRouter))
      expect(emitted).to eq(File.read(File.join(root, "spec/golden/schema.ts"))),
                         "the golden is stale, so the tsc run above proves nothing about " \
                         "the current emitter. Regenerate: UPDATE_GOLDEN=1 bundle exec rspec"
    end
  end
end
