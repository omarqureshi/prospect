# frozen_string_literal: true

module Prospect
  # What gets deployed, computed once.
  #
  # Both the CDK construct and the packager need this answer, and they must
  # never disagree: if packaging builds three artifacts and CDK synthesises two
  # functions, you deploy a function whose code was never built — and find out
  # on the first request. Sharing the computation makes that class of bug
  # unrepresentable rather than merely unlikely.
  module Units
    Unit = Struct.new(:name, :procedures, :route, keyword_init: true) do
      # Directory name for the built artifact, and the value of PROSPECT_UNIT.
      def to_s = name
    end

    module_function

    def for(router, granularity: :per_router, mount: "/rpc")
      case granularity
      when :single
        [Unit.new(name: "app", procedures: router.procedures, route: "#{mount}/{proxy+}")]
      when :per_procedure
        router.procedures.map do |p|
          Unit.new(name: p.id, procedures: [p], route: "#{mount}/#{p.path}/#{p.name}")
        end
      when :per_router
        per_router(router, mount)
      else
        raise ArgumentError, "unknown granularity #{granularity.inspect}"
      end
    end

    # One unit per mounted router, except procedures asking for their own via
    # `deploy: { granularity: :dedicated }`. Those get an exact route, which API
    # Gateway prefers over the greedy one — so a hot or expensive procedure peels
    # off without any client noticing.
    def per_router(router, mount)
      router.procedures.group_by(&:path).flat_map do |path, procedures|
        dedicated, shared = procedures.partition { |p| p.deploy[:granularity] == :dedicated }

        units = dedicated.map do |p|
          Unit.new(name: p.id, procedures: [p], route: "#{mount}/#{p.path}/#{p.name}")
        end
        if shared.any?
          units << Unit.new(name: path.to_s, procedures: shared,
                            route: "#{mount}/#{path}/{proxy+}")
        end
        units
      end
    end
  end
end
