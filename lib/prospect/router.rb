# frozen_string_literal: true

module Prospect
  Procedure = Struct.new(
    :path, :name, :kind, :input, :output, :errors, :deploy, :middleware, :handler,
    keyword_init: true
  ) do
    # Dotted id: "posts.feed". The wire URL uses slashes (/rpc/posts/feed) so the
    # API Gateway can route on the unit prefix — see DESIGN.md §6.
    def id = "#{path}.#{name}"
    def url_path = "/#{path}/#{name}"
  end

  # The authoring DSL. A Router is both a namespace of procedures and a
  # deployment unit — one service, one Lambda under :per_router granularity.
  class Router
    class << self
      def path(value = nil)
        @path = value if value
        @path
      end

      def context(klass = nil)
        @context_class = klass if klass
        @context_class || (superclass.respond_to?(:context) ? superclass.context : nil)
      end

      def deploy(**opts)
        @deploy = (@deploy || {}).merge(opts)
      end

      def deploy_config = @deploy || {}

      # Middleware scoping. bookface-rpc DESIGN §6.1 flags this shape as
      # unsettled: it reads well but hides its extent in a long file.
      def authenticated(&block)
        with_middleware(:authenticated, &block)
      end

      def with_middleware(*names)
        unknown = names - Dispatcher::MIDDLEWARE.keys
        if unknown.any?
          raise DefinitionError,
                "#{self}: unknown middleware #{unknown.map(&:inspect).join(', ')}. " \
                "Known: #{Dispatcher::MIDDLEWARE.keys.map(&:inspect).join(', ')}"
        end

        previous = @middleware || []
        @middleware = previous + names
        yield
      ensure
        @middleware = previous
      end

      def query(name, **opts, &handler)   = define(name, :query, **opts, &handler)
      def mutation(name, **opts, &handler) = define(name, :mutation, **opts, &handler)

      def mount(router)
        unless router.is_a?(Class) && router < Prospect::Router
          raise DefinitionError,
                "#{self}: can only mount a Prospect::Router, got #{router.inspect}"
        end
        raise DefinitionError, "#{self}: cannot mount itself" if router == self

        clash = mounted.find { |m| m.path == router.path }
        if clash
          raise DefinitionError,
                "#{self}: #{router} and #{clash} both use path #{router.path.inspect}, " \
                "so their procedures would collide"
        end

        mounted << router
      end

      def mounted = @mounted ||= []

      def own_procedures = @own_procedures ||= []

      # Flattened across mounts — what the dispatcher, the emitters and the CDK
      # construct all read.
      def procedures
        own_procedures + mounted.flat_map(&:procedures)
      end

      # Deployment units: each mounted router is one, plus any procedure that
      # asked for its own via `deploy: { ... }` at the procedure level.
      def units
        (mounted.empty? ? [self] : mounted).flat_map do |router|
          [router] + router.own_procedures.select { |p| p.deploy[:granularity] == :dedicated }
        end
      end

      private

      # Every check here fires at load time rather than on the first request.
      # For a framework the message *is* the API: a misuse that surfaces as
      # `NoMethodError on nil` three layers down is a defect, not a user error.
      def define(name, kind, input:, output:, errors: [], deploy: {}, &handler)
        raise DefinitionError, "#{self}: declare `path` before any procedure" unless path

        unless handler
          raise DefinitionError, "#{self}: #{path}.#{name} has no handler block"
        end

        if own_procedures.any? { |p| p.name == name }
          raise DefinitionError, "#{self}: #{path}.#{name} is declared twice"
        end

        check_deploy!(name, deploy)
        check_struct!(name, "input", input)
        check_struct!(name, "output", output)
        errors.each { |e| check_error!(name, e) }

        own_procedures << Procedure.new(
          path: path, name: name, kind: kind,
          input: input, output: output, errors: errors,
          deploy: deploy, middleware: (@middleware || []).dup,
          handler: handler
        )
      end

      # A misspelled or unsupported deploy key would otherwise be ignored in
      # silence: bookface asked for `timeout: 60` where the construct reads
      # `timeout_seconds`, and the procedure quietly kept the 10s default. A
      # deployment setting that does nothing is worse than one that fails.
      DEPLOY_KEYS = %i[memory_size timeout_seconds granularity].freeze

      def check_deploy!(name, deploy)
        unknown = deploy.keys - DEPLOY_KEYS
        return if unknown.empty?

        raise DefinitionError,
              "#{self}: #{path}.#{name} has unknown deploy #{unknown.map(&:inspect).join(', ')}. " \
              "Known: #{DEPLOY_KEYS.map(&:inspect).join(', ')}"
      end

      def check_struct!(name, role, klass)
        return if klass.is_a?(Class) && klass < T::Struct

        raise DefinitionError,
              "#{self}: #{path}.#{name} #{role} must be a T::Struct subclass, " \
              "got #{klass.inspect}"
      end

      def check_error!(name, klass)
        return if klass.is_a?(Class) && klass <= Prospect::Error

        raise DefinitionError,
              "#{self}: #{path}.#{name} declared #{klass.inspect} in `errors:`, " \
              "which is not a Prospect::Error"
      end
    end
  end
end
