# frozen_string_literal: true

require "tmpdir"
require "fileutils"

# Planning is pure, so all of this runs without Docker. A real build measured 23s
# per bundle on x86_64 and 941s emulated (DESIGN.md §6) — far too slow for a spec
# run, which is exactly why Plan and Builder are separate objects.
RSpec.describe Prospect::Package do
  around do |example|
    Dir.mktmpdir("prospect-pkg") do |dir|
      @root = dir
      FileUtils.mkdir_p(File.join(dir, "units"))
      File.write(File.join(dir, "common.gemfile"), %(gem "prospect"\ngem "sorbet-runtime"\n))
      # echo and other resolve identically; other.touch adds a gem.
      File.write(File.join(dir, "units/echo.gemfile"),
                 %(eval_gemfile File.expand_path("../common.gemfile", __dir__)\n))
      File.write(File.join(dir, "units/other.touch.gemfile"),
                 %(eval_gemfile File.expand_path("../common.gemfile", __dir__)\ngem "aws-sdk-s3"\n))
      example.run
    end
  end

  def plan(**opts)
    described_class.plan(
      router: Fixtures::AppRouter,
      router_const: "Fixtures::AppRouter",
      context_builder: "Fixtures::Context.method(:from_event)",
      root: @root, out: File.join(@root, "build"),
      **opts
    )
  end

  describe "units" do
    it "uses the shared unit computation, not its own" do
      expect(plan.units.map(&:name)).to contain_exactly("echo", "other.touch")
    end

    it "follows granularity" do
      expect(plan(granularity: :single).units.map(&:name)).to eq(["app"])
      expect(plan(granularity: :per_procedure).units.length)
        .to eq(Fixtures::AppRouter.procedures.length)
    end
  end

  describe "gemfiles" do
    # Falling back to the whole app's dependencies would defeat the slicing
    # silently — nobody notices until cold starts get slow.
    it "refuses a unit with no gemfile rather than guessing" do
      expect { plan(granularity: :single).builds }
        .to raise_error(Prospect::Package::Error, /no gemfile for unit "app"/)
    end
  end

  describe "dedicated procedures" do
    # A procedure promoted to its own Lambda is a subset of its router, so
    # reusing the router's gemfile is correct rather than a guess.
    it "falls back to the router's gemfile" do
      # other.touch is :dedicated in the fixture; only other.touch.gemfile exists,
      # so remove it and check the fallback finds a router-level one.
      FileUtils.mv(File.join(@root, "units/other.touch.gemfile"),
                   File.join(@root, "units/other.gemfile"))
      unit = plan.units.find { |u| u.name == "other.touch" }
      expect(plan.gemfile_for(unit)).to end_with("units/other.gemfile")
    end

    it "still refuses when neither exists" do
      FileUtils.rm(File.join(@root, "units/other.touch.gemfile"))
      unit = plan.units.find { |u| u.name == "other.touch" }
      expect { plan.gemfile_for(unit) }
        .to raise_error(Prospect::Package::Error, /tried.*other\.touch\.gemfile.*other\.gemfile/m)
    end
  end

  describe "deduplication by gem set" do
    # The mitigation for the build-count multiplier in §6. Without it, N units
    # means N installs even when most share the same handful of gems.
    it "groups units whose gemfiles expand identically" do
      File.write(File.join(@root, "units/other.touch.gemfile"),
                 %(eval_gemfile File.expand_path("../common.gemfile", __dir__)\n))

      builds = plan.builds
      expect(builds.length).to eq(1)
      expect(builds.first.units.map(&:name)).to contain_exactly("echo", "other.touch")
    end

    it "keeps units with different dependencies apart" do
      expect(plan.builds.length).to eq(2)
    end

    # Found by running this on bookface: two services with identical gems built
    # twice because one of them had a comment explaining itself.
    it "ignores comments and blank lines, which are not dependencies" do
      File.write(File.join(@root, "units/other.touch.gemfile"), <<~GEMFILE)
        # This service signs S3 URLs.
        eval_gemfile File.expand_path("../common.gemfile", __dir__)

        gem "aws-sdk-s3"   # presigning
      GEMFILE
      File.write(File.join(@root, "units/echo.gemfile"), <<~GEMFILE)
        eval_gemfile File.expand_path("../common.gemfile", __dir__)
        gem "aws-sdk-s3"
      GEMFILE

      expect(plan.builds.length).to eq(1)
    end

    # A digest of the one-line file would call these identical, because the
    # difference lives in the file they both eval.
    it "digests the expanded gemfile, not the literal file" do
      File.write(File.join(@root, "units/echo.gemfile"),
                 %(eval_gemfile File.expand_path("../shared.gemfile", __dir__)\n))
      File.write(File.join(@root, "shared.gemfile"), %(gem "totally-different"\n))

      digests = plan.units.map { |u| plan.digest_for(u) }
      expect(digests.uniq.length).to eq(2)
    end
  end

  describe "the generated handler" do
    subject(:source) { plan.handler_source(plan.units.find { |u| u.name == "echo" }) }

    it "requires the standalone bundle setup" do
      expect(source).to include(%(require_relative "vendor/bundle/bundler/setup"))
    end

    # The single largest cold-start lever measured: ~630ms at 512MB. Asserted
    # against the code rather than the whole file, since the generated comment
    # legitimately explains why Bundler is avoided.
    it "never loads Bundler at runtime" do
      code = source.lines.reject { |l| l.strip.start_with?("#") }.join
      expect(code).not_to include("bundle exec", "Bundler.setup", "Bundler.require")
    end

    it "scopes the handler to its unit" do
      expect(source).to include(%(unit: "echo"))
    end

    it "wires the caller's context builder" do
      expect(source).to include("Fixtures::Context.method(:from_event)")
    end

    it "defines the entry point Lambda calls" do
      expect(source).to include("def handle(event:, context:)")
    end

    it "records which procedures it serves, for anyone reading the artifact" do
      expect(source).to include("echo.boom, echo.explode, echo.ping, echo.secret")
    end

    it "is valid Ruby" do
      expect { RubyVM::AbstractSyntaxTree.parse(source) }.not_to raise_error
    end
  end

  describe "building" do
    # Fake shell: records the commands and fakes the install's output, so the
    # staging logic is exercised without Docker.
    let(:commands) { [] }
    let(:shell) do
      lambda do |*cmd|
        commands << cmd
        if cmd.last.include?("bundle install")
          # The bundle lands in the dir mounted at /vendor, which is what the
          # builder later copies into each unit.
          mount = cmd.find { |c| c.to_s.end_with?(":/vendor") }
          vendor = mount.split(":").first
          FileUtils.mkdir_p(File.join(vendor, "bundler"))
          File.write(File.join(vendor, "bundler/setup.rb"), "# stub\n")
        end
        ["", true]
      end
    end

    def build!(the_plan = plan)
      described_class.build(the_plan, verify: false, shell: shell)
    end

    it "installs once per distinct gem set, not once per unit" do
      File.write(File.join(@root, "units/other.touch.gemfile"),
                 %(eval_gemfile File.expand_path("../common.gemfile", __dir__)\n))
      build!
      installs = commands.count { |c| c.last.include?("bundle install") }
      expect(installs).to eq(1)
    end

    it "installs standalone, so Bundler is never loaded at runtime" do
      build!
      expect(commands.map(&:last).join).to include("bundle install --standalone")
    end

    # A private gem source needs credentials at build time, and the container
    # inherits nothing from the host.
    it "forwards the configured environment into the build container" do
      build!(plan(env: { "BUNDLE_EXAMPLE__COM" => "user:token" }))
      install = commands.find { |c| c.last.include?("bundle install") }
      expect(install.each_cons(2).to_a).to include(["-e", "BUNDLE_EXAMPLE__COM=user:token"])
    end

    it "forwards nothing by default" do
      build!
      install = commands.find { |c| c.last.include?("bundle install") }
      # The -e flags specifically: the install script itself exports
      # BUNDLE_PATH, so matching the whole command would always hit.
      passed = install.each_cons(2).select { |flag, _| flag == "-e" }.map(&:last)
      expect(passed).to eq(["HOME=/tmp"])
    end

    it "builds in the Lambda image on the configured platform" do
      build!
      expect(commands.first).to include("--platform", "linux/amd64",
                                        "public.ecr.aws/sam/build-ruby4.0")
    end

    it "gives every unit its own directory with a handler and a bundle" do
      build!
      plan.units.each do |unit|
        dir = File.join(@root, "build", unit.name)
        expect(File).to exist(File.join(dir, "handler.rb"))
        expect(File).to exist(File.join(dir, "vendor/bundle/bundler/setup.rb"))
      end
    end

    it "copies the declared application sources" do
      FileUtils.mkdir_p(File.join(@root, "app"))
      File.write(File.join(@root, "app/thing.rb"), "# app code\n")
      build!(plan(sources: %w[app]))
      expect(File).to exist(File.join(@root, "build/echo/app/thing.rb"))
    end
  end

  describe "the authorizer unit" do
    let(:commands) { [] }
    let(:shell) do
      lambda do |*cmd|
        commands << cmd
        if cmd.last.include?("bundle install")
          mount = cmd.find { |c| c.to_s.end_with?(":/vendor") }
          vendor = mount.split(":").first
          FileUtils.mkdir_p(File.join(vendor, "bundler"))
          File.write(File.join(vendor, "bundler/setup.rb"), "# stub\n")
        end
        ["", true]
      end
    end

    before do
      File.write(File.join(@root, "units/authorizer.gemfile"),
                 %(source "https://rubygems.org"\ngem "prospect"\ngem "jwt"\n))
    end

    it "is only planned when asked for" do
      expect(plan.units.map(&:name)).not_to include("authorizer")
      expect(plan(authorizer: true).units.map(&:name)).to include("authorizer")
    end

    it "gets a handler that reads its config from the environment" do
      source = plan(authorizer: true).handler_source(
        plan(authorizer: true).units.find { |u| u.name == "authorizer" }
      )
      expect(source).to include('ENV.fetch("PROSPECT_ISSUER")', "Prospect::Authorizer.handler")
      expect(source).not_to include("AppRouter")
    end

    # It serves no procedures and needs none of the app — only prospect and jwt.
    it "ships without the application sources" do
      FileUtils.mkdir_p(File.join(@root, "app"))
      File.write(File.join(@root, "app/thing.rb"), "# app code\n")
      described_class.build(plan(authorizer: true, sources: %w[app]),
                            verify: false, shell: shell)
      expect(File).to exist(File.join(@root, "build/echo/app/thing.rb"))
      expect(File).not_to exist(File.join(@root, "build/authorizer/app/thing.rb"))
    end
  end

  describe "the plan as a document" do
    it "describes what would be built, for review or a dry run" do
      doc = plan.to_h
      expect(doc["granularity"]).to eq("per_router")
      expect(doc["units"].map { |u| u["name"] }).to contain_exactly("echo", "other.touch")
      expect(doc["units"].first).to include("route", "digest", "procedures")
    end
  end
end
