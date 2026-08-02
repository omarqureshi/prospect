# Measures the *controllable* portion of Lambda cold start: everything from
# process start to "ready to serve the first request". AWS sandbox provisioning
# is fixed overhead we can't influence and isn't measured here.
#
# One scenario per process — warm requires would defeat the point.
#
#   ruby bench.rb <scenario>   # prints elapsed ms

T0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)

STRUCT_COUNT = Integer(ENV.fetch("STRUCTS", "50"))
PROPS        = %i[id name email title body slug status kind]

def define_structs!
  STRUCT_COUNT.times do |i|
    klass = Class.new(T::Struct) do
      PROPS.each { |p| const p, String }
      const :count,     Integer
      const :active,    T::Boolean
      const :optional,  T.nilable(String)
    end
    Object.const_set("Bench#{i}", klass)
  end
end

def define_sigs!
  STRUCT_COUNT.times do |i|
    klass = Class.new do
      extend T::Sig
      sig { params(x: String).returns(String) }
      def call(x) = x
    end
    Object.const_set("Svc#{i}", klass)
  end
end

case ARGV[0]
when "baseline"
  # bare ruby boot only

when "json"
  require "json"

when "sorbet"
  require "sorbet-runtime"

when "sorbet+structs"
  require "sorbet-runtime"
  define_structs!

when "sorbet+structs+validate"
  require "sorbet-runtime"
  define_structs!
  # first from_hash pays lazy setup costs
  h = PROPS.to_h { |p| [p.to_s, "x"] }.merge("count" => 1, "active" => true)
  STRUCT_COUNT.times { |i| Object.const_get("Bench#{i}").from_hash(h) }

when "sorbet+sigs"
  require "sorbet-runtime"
  define_sigs!
  STRUCT_COUNT.times { |i| Object.const_get("Svc#{i}").new.call("x") }

when "sorbet+sigs+never"
  require "sorbet-runtime"
  T::Configuration.default_checked_level = :never
  define_sigs!
  STRUCT_COUNT.times { |i| Object.const_get("Svc#{i}").new.call("x") }

when "full"
  # realistic: framework deps + structs + sigs exercised once
  require "sorbet-runtime"
  require "json"
  require "rack"
  define_structs!
  define_sigs!
  h = PROPS.to_h { |p| [p.to_s, "x"] }.merge("count" => 1, "active" => true)
  STRUCT_COUNT.times { |i| Object.const_get("Bench#{i}").from_hash(h) }
  STRUCT_COUNT.times { |i| Object.const_get("Svc#{i}").new.call("x") }

else
  abort "unknown scenario: #{ARGV[0].inspect}"
end

puts format("%.1f", (Process.clock_gettime(Process::CLOCK_MONOTONIC) - T0) * 1000)
