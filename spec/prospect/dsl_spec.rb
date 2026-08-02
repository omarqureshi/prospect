# frozen_string_literal: true

# For a framework, the error you get when you hold it wrong is part of the API.
# A misuse that surfaces as `NoMethodError on nil` three layers down — or worse,
# on the first production request — is a defect in the framework, not the app.
#
# So every case here asserts two things: that it fails at LOAD time, and that
# the message names the thing you got wrong.
RSpec.describe "router DSL misuse" do
  def router(&block) = Class.new(Prospect::Router, &block)

  describe "declaration order" do
    it "refuses a procedure declared before `path`" do
      expect {
        router do
          query(:x, input: Fixtures::Empty, output: Fixtures::Empty) { Fixtures::Empty.new }
        end
      }.to raise_error(Prospect::DefinitionError, /declare `path` before any procedure/)
    end
  end

  describe "handlers" do
    # Without this the handler is nil and the failure is a NoMethodError on the
    # first request to that procedure — possibly in production, long after the
    # typo.
    it "refuses a procedure with no block" do
      expect {
        router do
          path :a
          query :x, input: Fixtures::Empty, output: Fixtures::Empty
        end
      }.to raise_error(Prospect::DefinitionError, /a\.x has no handler block/)
    end
  end

  describe "duplicate names" do
    # Previously the second silently won, because the dispatcher indexes
    # procedures into a hash by id. A contract can't have two shapes.
    it "refuses the same procedure name twice" do
      expect {
        router do
          path :a
          query(:x, input: Fixtures::Empty, output: Fixtures::Empty) { Fixtures::Empty.new }
          query(:x, input: Fixtures::Ping, output: Fixtures::Matrix) { Fixtures::MATRIX_VALUE }
        end
      }.to raise_error(Prospect::DefinitionError, /a\.x is declared twice/)
    end

    it "allows the same name under a different path" do
      a = router do
        path :a
        query(:x, input: Fixtures::Empty, output: Fixtures::Empty) { Fixtures::Empty.new }
      end
      b = router do
        path :b
        query(:x, input: Fixtures::Empty, output: Fixtures::Empty) { Fixtures::Empty.new }
      end

      app = Class.new(Prospect::Router)
      app.mount(a)
      app.mount(b)
      expect(app.procedures.map(&:id)).to contain_exactly("a.x", "b.x")
    end
  end

  describe "input and output types" do
    it "refuses an input that is not a T::Struct" do
      expect {
        router do
          path :a
          query(:x, input: Hash, output: Fixtures::Empty) { Fixtures::Empty.new }
        end
      }.to raise_error(Prospect::DefinitionError, /input must be a T::Struct subclass, got Hash/)
    end

    it "refuses an output that is not a T::Struct" do
      expect {
        router do
          path :a
          query(:x, input: Fixtures::Empty, output: String) { "" }
        end
      }.to raise_error(Prospect::DefinitionError, /output must be a T::Struct subclass, got String/)
    end

    it "names the procedure, not just the type" do
      expect {
        router do
          path :reports
          query(:export, input: Symbol, output: Fixtures::Empty) { Fixtures::Empty.new }
        end
      }.to raise_error(Prospect::DefinitionError, /reports\.export input/)
    end
  end

  describe "declared errors" do
    it "refuses an error class that is not a Prospect::Error" do
      expect {
        router do
          path :a
          query(:x, input: Fixtures::Empty, output: Fixtures::Empty,
                    errors: [ArgumentError]) { Fixtures::Empty.new }
        end
      }.to raise_error(Prospect::DefinitionError, /ArgumentError.*not a Prospect::Error/m)
    end

    it "accepts Prospect's own errors and app subclasses of them" do
      custom = Class.new(Prospect::Error) { const :detail, String }
      expect {
        router do
          path :a
          query(:x, input: Fixtures::Empty, output: Fixtures::Empty,
                    errors: [Prospect::NotFound, custom]) { Fixtures::Empty.new }
        end
      }.not_to raise_error
    end
  end

  describe "deploy settings" do
    # Found by synthesising bookface: it asked for `timeout: 60` where the
    # construct reads `timeout_seconds`, and the procedure silently kept the
    # 10s default. A deployment setting that does nothing is worse than one
    # that fails.
    it "refuses an unknown deploy key rather than ignoring it" do
      expect {
        router do
          path :a
          query(:x, input: Fixtures::Empty, output: Fixtures::Empty,
                    deploy: { timeout: 60 }) { Fixtures::Empty.new }
        end
      }.to raise_error(Prospect::DefinitionError, /unknown deploy :timeout.*Known:.*timeout_seconds/m)
    end

    it "accepts the supported keys" do
      expect {
        router do
          path :a
          query(:x, input: Fixtures::Empty, output: Fixtures::Empty,
                    deploy: { memory_size: 2048, timeout_seconds: 60,
                              granularity: :dedicated }) { Fixtures::Empty.new }
        end
      }.not_to raise_error
    end
  end

  describe "mounting" do
    it "refuses a non-router" do
      expect { Class.new(Prospect::Router).mount(Object) }
        .to raise_error(Prospect::DefinitionError, /can only mount a Prospect::Router/)
    end

    it "refuses to mount itself" do
      app = Class.new(Prospect::Router)
      expect { app.mount(app) }.to raise_error(Prospect::DefinitionError, /cannot mount itself/)
    end

    # Two services claiming the same path produce colliding procedure ids, which
    # would silently shadow each other in the dispatcher's index.
    it "refuses two routers with the same path" do
      a = router { path :same }
      b = router { path :same }
      app = Class.new(Prospect::Router)
      app.mount(a)

      expect { app.mount(b) }
        .to raise_error(Prospect::DefinitionError, /both use path :same.*collide/m)
    end
  end

  describe "middleware" do
    # Previously an unknown name raised at dispatch — i.e. on a real request to
    # that procedure, not at boot.
    it "refuses an unknown middleware at load time, and lists the known ones" do
      expect {
        router do
          path :a
          with_middleware(:definitely_not_real) do
            query(:x, input: Fixtures::Empty, output: Fixtures::Empty) { Fixtures::Empty.new }
          end
        end
      }.to raise_error(Prospect::DefinitionError, /unknown middleware :definitely_not_real.*Known: :authenticated/m)
    end

    it "restores the previous scope after the block, including on error" do
      klass = router do
        path :a
        begin
          with_middleware(:authenticated) { raise "boom" }
        rescue RuntimeError
          nil
        end
        query(:after, input: Fixtures::Empty, output: Fixtures::Empty) { Fixtures::Empty.new }
      end

      expect(klass.own_procedures.first.middleware).to be_empty
    end
  end
end
