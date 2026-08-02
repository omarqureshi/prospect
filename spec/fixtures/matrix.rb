# frozen_string_literal: true

require "bigdecimal"
require "date"

# The fixture app. Two properties matter more than realism:
#
#   * HERMETIC — handlers return canned values. No database, no network, no
#     Docker. The moment core specs need infrastructure people stop running them.
#   * DELIBERATELY WEIRD — this is a *type matrix*, not a plausible app. It
#     exists to contain every shape the IR claims to represent, so one fixture
#     drives the IR specs, the validator specs and the emitter goldens.
module Fixtures
  class Colour < T::Enum
    enums do
      Red  = new("red")
      Blue = new("blue")
    end
  end

  class Nested < T::Struct
    const :label, String
  end

  # Self-referential, to prove the extractor's cycle breaking. Declared in two
  # steps because a class can't name itself inside its own body.
  class Tree < T::Struct
    const :label, String
  end
  class Tree
    const :children, T::Array[Tree], default: []
  end

  # Every representable shape, once.
  class Matrix < T::Struct
    const :str,     String
    const :int,     Integer
    const :flt,     Float
    const :flag,    T::Boolean          # a Sorbet union that is NOT a wire union
    const :at,      Time
    const :on,      Date
    const :money,   BigDecimal
    const :maybe,   T.nilable(String)   # also a union, also not one on the wire
    const :list,    T::Array[String]
    const :refs,    T::Array[Nested]
    const :lookup,  T::Hash[String, Integer]  # keys are DATA — never renamed
    const :nested,  Nested
    const :colour,  Colour
    const :tree,    Tree
    const :with_default, String, default: "x"
    const :two_words,    String                # exists purely to exercise camelCasing
  end

  # Nothing in the IR can represent a Symbol, so strict mode must reject this
  # at extraction rather than emitting an untypable client.
  class Unrepresentable < T::Struct
    const :sym, Symbol
  end

  class Empty < T::Struct; end

  class Ping < T::Struct
    const :who, String
    const :loud, T::Boolean, default: false
  end

  # Minimal context: just enough for the `authenticated` middleware to have
  # something to reject.
  class Context < T::Struct
    const :viewer, T.nilable(String)

    def authenticated!
      viewer || raise(Prospect::Unauthorized.new)
    end
  end

  class EchoRouter < Prospect::Router
    path :echo
    context Context
    deploy memory_size: 512

    query :ping, input: Ping, output: Matrix do |input, _ctx|
      MATRIX_VALUE
    end

    query :boom, input: Empty, output: Empty,
          errors: [Prospect::NotFound] do |_input, _ctx|
      raise Prospect::NotFound.new(resource: "thing", id: "1")
    end

    query :explode, input: Empty, output: Empty do |_input, _ctx|
      raise "handler blew up"
    end

    authenticated do
      query :secret, input: Empty, output: Empty do |_input, _ctx|
        Empty.new
      end
    end
  end

  class OtherRouter < Prospect::Router
    path :other
    context Context

    mutation :touch, input: Empty, output: Empty, deploy: { granularity: :dedicated } do |_i, _c|
      Empty.new
    end
  end

  class AppRouter < Prospect::Router
    mount EchoRouter
    mount OtherRouter
  end

  MATRIX_VALUE = Matrix.new(
    str: "s", int: 1, flt: 1.5, flag: true,
    at: Time.utc(2026, 1, 2, 3, 4, 5), on: Date.new(2026, 1, 2),
    money: BigDecimal("1.25"), maybe: nil,
    list: %w[a b], refs: [Nested.new(label: "n")],
    lookup: { "👍" => 2 }, nested: Nested.new(label: "deep"),
    colour: Colour::Red, tree: Tree.new(label: "root"),
    two_words: "yes"
  )
end
