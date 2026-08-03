# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"

module Prospect
  # Builds a deployable artifact per unit: the app's code, a generated handler
  # shim, and a standalone gem bundle sliced to that unit's dependencies.
  #
  # Planning is separated from building on purpose. The plan is pure and fast, so
  # it can be tested without Docker; only `Builder` shells out. That matters
  # because a real build measured 23s per bundle on x86_64 and 941s emulated
  # (DESIGN.md §6) — far too slow to sit in a spec run.
  module Package
    class Error < StandardError; end

    Build = Struct.new(:digest, :gemfile, :units, keyword_init: true)

    class Plan
      DEFAULTS = {
        out: "build",
        root: ".",
        granularity: :per_router,
        units_dir: "units",
        boot: "config/boot.rb",
        sources: %w[app config].freeze,
        image: "public.ecr.aws/sam/build-ruby4.0",
        platform: "linux/amd64", # x86_64 default: emulated arm64 measured 41x slower
        # Extra host paths to mount, for `path:` gems living outside the app
        # root — normal during development, absent once gems are published.
        mounts: [].freeze
      }.freeze

      def initialize(router:, router_const:, context_builder:, **opts)
        @router = router
        @router_const = router_const
        @context_builder = context_builder
        @opts = DEFAULTS.merge(opts)
      end

      AUTHORIZER = "authorizer"

      def units
        @units ||= Units.for(@router, granularity: @opts[:granularity]) +
                   (@opts[:authorizer] ? [authorizer_unit] : [])
      end

      # The authorizer is a deployment unit but not a router unit: it serves no
      # procedures and needs none of the app's code, only prospect and jwt. Its
      # configuration arrives from the environment the CDK sets, so the handler
      # is generic and nothing about it is fixed at build time.
      def authorizer_unit
        Units::Unit.new(name: AUTHORIZER, procedures: [], route: nil)
      end

      def authorizer?(unit) = unit.name == AUTHORIZER

      # Environment a unit needs merely to BOOT, supplied during verification.
      # The authorizer reads its configuration with ENV.fetch and no default —
      # correct, since a missing issuer must not silently become "trust nobody"
      # or "trust everybody" — so verification has to provide placeholders.
      def verify_env(unit)
        return {} unless authorizer?(unit)

        { "PROSPECT_ISSUER" => "https://verify.invalid",
          "PROSPECT_AUDIENCE" => "verify", "PROSPECT_ANONYMOUS" => "" }
      end

      %i[out root units_dir boot sources image platform mounts].each do |key|
        define_method(key) { @opts[key] }
      end

      def unit_dir(unit) = File.join(out, unit.name)

      def gemfile_for(unit)
        candidates = [unit.name]
        # A procedure promoted to its own Lambda (`granularity: :dedicated`)
        # falls back to its router's gemfile — "posts.destroy" to "posts". That
        # is not guessing: a dedicated procedure's dependencies are a subset of
        # its router's, so the fallback is correct and it removes the pointless
        # step of copying a gemfile to rename it.
        candidates << unit.name.split(".").first if unit.name.include?(".")

        found = candidates.lazy
                          .map { |n| File.join(root, units_dir, "#{n}.gemfile") }
                          .find { |f| File.exist?(f) }
        return found if found

        # With none of them present it is a hard error, not a fallback to the
        # whole app's dependencies — quietly shipping every gem would defeat the
        # slicing, and nobody would notice until cold starts got slow.
        raise Error, "no gemfile for unit #{unit.name.inspect}; tried " \
                     "#{candidates.map { |n| "#{units_dir}/#{n}.gemfile" }.join(', ')}"
      end

      # Units whose gemfiles resolve identically share one bundle build.
      #
      # This is the mitigation for the build-count multiplier in §6: N units
      # naively means N installs, and most services depend on the same handful of
      # gems. Digesting the gemfile plus everything it eval_gemfile's keeps the
      # grouping honest — two units that both eval common.gemfile and add nothing
      # are genuinely identical.
      def builds
        units.group_by { |u| digest_for(u) }
             .map { |digest, group| Build.new(digest: digest, gemfile: gemfile_for(group.first), units: group) }
      end

      def digest_for(unit)
        Digest::SHA256.hexdigest(normalize(expand_gemfile(gemfile_for(unit))))[0, 16]
      end

      # Comments and blank lines are not dependencies. Without this, two units
      # with identical gems build twice because one of them explains itself —
      # which is exactly what bookface's `posts` and `uploads` gemfiles did.
      def normalize(source)
        source.lines
              .map { |l| l.sub(/#.*$/, "").strip }
              .reject(&:empty?)
              .join("\n")
      end

      # Inline eval_gemfile'd files so the digest reflects real dependencies
      # rather than a one-line file that happens to differ in whitespace.
      def expand_gemfile(path, seen = [])
        return "" if seen.include?(path)

        seen << path
        File.read(path).lines.map { |line|
          if (m = line.match(/eval_gemfile\s+.*?["']([^"']+)["']|eval_gemfile\s+File\.expand_path\(["']([^"']+)["']/))
            target = File.expand_path(m[1] || m[2], File.dirname(path))
            File.exist?(target) ? expand_gemfile(target, seen) : line
          else
            line
          end
        }.join
      end

      def handler_source(unit)
        return authorizer_handler if authorizer?(unit)

        procedure_handler(unit)
      end

      def authorizer_handler
        <<~RUBY
          # Generated by Prospect. Do not edit.
          #
          # Optional-auth Lambda authorizer: verifies a token when one is present
          # and lets anonymous callers through on the declared public procedures.
          # Configuration comes from the environment the CDK sets, so this file
          # is identical across deployments.
          require_relative "vendor/bundle/bundler/setup"
          require "prospect/authorizer"

          HANDLER = Prospect::Authorizer.handler(
            issuer:    ENV.fetch("PROSPECT_ISSUER"),
            audience:  ENV.fetch("PROSPECT_AUDIENCE", "").split(","),
            anonymous: ENV.fetch("PROSPECT_ANONYMOUS", "").split(","),
            mount:     ENV.fetch("PROSPECT_MOUNT", "/rpc")
          )

          def handle(event:, context:)
            HANDLER.call(event, context)
          end
        RUBY
      end

      def procedure_handler(unit)
        <<~RUBY
          # Generated by Prospect for unit #{unit.name.inspect}. Do not edit.
          #
          # Procedures served: #{unit.procedures.map(&:id).sort.join(', ')}
          #
          # NOTE the standalone require rather than `bundle exec`: Bundler's
          # runtime costs ~630ms at 512MB, four times what sorbet-runtime costs
          # (DESIGN.md §6). This is the single largest cold-start lever.
          require_relative "vendor/bundle/bundler/setup"
          require_relative "#{@opts[:boot].sub(/\.rb\z/, '')}"

          HANDLER = Prospect::Lambda.handler(
            #{@router_const},
            unit: #{unit.name.inspect},
            context_builder: #{@context_builder}
          )

          def handle(event:, context:)
            HANDLER.call(event, context)
          end
        RUBY
      end

      def to_h
        { "granularity" => @opts[:granularity].to_s,
          "units" => units.map { |u|
            { "name" => u.name, "route" => u.route, "digest" => digest_for(u),
              "procedures" => u.procedures.map(&:id).sort }
          } }
      end
    end

    # Runs the plan. Everything that touches Docker or the filesystem lives here.
    class Builder
      def initialize(plan, verify: true, shell: method(:system_capture))
        @plan = plan
        @verify = verify
        @shell = shell
      end

      def call
        FileUtils.mkdir_p(@plan.out)
        @plan.builds.each { |build| install(build) }
        @plan.units.each { |unit| stage(unit) }
        verify! if @verify
        @plan.units
      end

      private

      # One `bundle install --standalone` per distinct gem set, run IN PLACE via
      # BUNDLE_GEMFILE rather than by copying gemfiles somewhere flat.
      #
      # Copying was the first attempt and it fails on real apps for two reasons:
      # a unit gemfile is a *fragment* (the root Gemfile supplies `source`), and
      # `path:` dependencies resolve relative to where the gemfile lives. Both
      # work if the app is mounted at its own absolute path — which also lets a
      # path gem outside the app root resolve, given a mount for it.
      def install(build)
        vendor = bundle_dir(build.digest)
        return if File.directory?(File.join(vendor, "bundler"))

        FileUtils.mkdir_p(vendor)
        gemfile = File.expand_path(@plan.gemfile_for(build.units.first))

        out, ok = docker(vendor, <<~SH)
          set -e
          export BUNDLE_GEMFILE=#{gemfile}
          export BUNDLE_PATH=/vendor
          bundle install --standalone
        SH
        raise Error, "bundle install failed for #{File.basename(gemfile)}:\n#{out}" unless ok

        vendor_path_gems!(vendor)
      end

      # `bundle install --standalone` does NOT vendor `path:` gems. It writes an
      # absolute host path into setup.rb:
      #
      #   $:.unshift "/home/you/repos/prospect/lib"
      #
      # which does not exist inside a Lambda, so the artifact deploys fine and
      # then LoadErrors on the first invocation. Found by the verify step, which
      # is precisely the failure it exists to catch.
      #
      # So copy each path gem into the bundle and rewrite the entry to a relative
      # one, making the artifact self-contained. Once a gem is published this is
      # a no-op.
      def vendor_path_gems!(vendor)
        setup = File.join(vendor, "bundler", "setup.rb")
        return unless File.exist?(setup)

        source = File.read(setup)
        external = source.scan(/^\$:\.unshift "(\/[^"]+)"$/).flatten
                         .reject { |p| p.start_with?(vendor) }
        return if external.empty?

        external.each do |lib|
          root = File.dirname(lib)
          name = File.basename(root)
          dest = File.join(vendor, "path-gems", name)

          FileUtils.mkdir_p(File.dirname(dest))
          FileUtils.rm_rf(dest)
          FileUtils.mkdir_p(dest)
          # lib and the gemspec are all a load path needs; skip .git, specs and
          # build output so the artifact stays small.
          %w[lib exe].each do |sub|
            from = File.join(root, sub)
            FileUtils.cp_r(from, dest) if File.exist?(from)
          end

          relative = %(File.expand_path("\#{__dir__}/../path-gems/#{name}/#{File.basename(lib)}"))
          source = source.sub(%($:.unshift "#{lib}"), "$:.unshift #{relative}")
        end

        File.write(setup, source)
      end

      def stage(unit)
        dir = @plan.unit_dir(unit)
        FileUtils.rm_rf(dir)
        FileUtils.mkdir_p(dir)

        unless @plan.authorizer?(unit)
          @plan.sources.each do |src|
            from = File.join(@plan.root, src)
            FileUtils.cp_r(from, dir) if File.exist?(from)
          end
        end

        FileUtils.mkdir_p(File.join(dir, "vendor"))
        FileUtils.cp_r(bundle_dir(@plan.digest_for(unit)), File.join(dir, "vendor/bundle"))
        File.write(File.join(dir, "handler.rb"), @plan.handler_source(unit))
      end

      # Boot every built artifact and require its handler. Unsound slicing caught
      # at build time is an inconvenience; caught at invoke time it is an outage
      # (DESIGN.md §6, step 4).
      def verify!
        @plan.units.each do |unit|
          out, ok = verify_in(@plan.unit_dir(unit), @plan.verify_env(unit),
                              # A top-level `def` is a private method on Object, so respond_to? must be
          # told to include private methods — which is also how the Lambda runtime
          # reaches it.
          %(ruby -e 'require "./handler"; raise "no handle method" unless respond_to?(:handle, true)'))
          raise Error, "unit #{unit.name} does not boot:\n#{out}" unless ok
        end
      end

      def bundle_dir(digest) = File.expand_path(File.join(@plan.out, ".bundles", digest))

      # Every path is mounted at its own absolute location, so relative `path:`
      # dependencies resolve exactly as they do on the host.
      def docker(vendor, script)
        mounts = ([File.expand_path(@plan.root)] + @plan.mounts)
                 .flat_map { |m| ["-v", "#{m}:#{m}"] }
        @shell.call(
          "docker", "run", "--rm", "--platform", @plan.platform,
          # Run as the invoking user, or every built file lands on the host
          # owned by root and the next `rm -rf build` fails. HOME must be
          # writable for Bundler once we are not root.
          "--user", "#{Process.uid}:#{Process.gid}", "-e", "HOME=/tmp",
          *mounts, "-v", "#{vendor}:/vendor",
          "-w", File.expand_path(@plan.root),
          "--entrypoint", "bash", @plan.image, "-c", script
        )
      end

      def verify_in(dir, env, script)
        @shell.call(
          "docker", "run", "--rm", "--platform", @plan.platform,
          "--user", "#{Process.uid}:#{Process.gid}", "-e", "HOME=/tmp",
          *env.flat_map { |k, v| ["-e", "#{k}=#{v}"] },
          "-v", "#{File.expand_path(dir)}:/w", "-w", "/w",
          "--entrypoint", "bash", @plan.image, "-c", script
        )
      end

      def system_capture(*cmd)
        require "open3"
        out, status = Open3.capture2e(*cmd)
        [out, status.success?]
      end
    end

    module_function

    def plan(**kwargs) = Plan.new(**kwargs)

    def build(plan, **opts) = Builder.new(plan, **opts).call
  end
end
