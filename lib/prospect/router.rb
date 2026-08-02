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
        previous = @middleware || []
        @middleware = previous + names
        yield
      ensure
        @middleware = previous
      end

      def query(name, **opts, &handler)   = define(name, :query, **opts, &handler)
      def mutation(name, **opts, &handler) = define(name, :mutation, **opts, &handler)

      def mount(router)
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

      def define(name, kind, input:, output:, errors: [], deploy: {}, &handler)
        raise ArgumentError, "#{self}: `path` must be declared before procedures" unless path

        own_procedures << Procedure.new(
          path: path, name: name, kind: kind,
          input: input, output: output, errors: errors,
          deploy: deploy, middleware: (@middleware || []).dup,
          handler: handler
        )
      end
    end
  end
end
