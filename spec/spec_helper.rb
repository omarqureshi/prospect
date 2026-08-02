# frozen_string_literal: true

require "prospect"
require_relative "fixtures/matrix"

RSpec.configure do |config|
  config.expect_with(:rspec) { |e| e.syntax = :expect }
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed
end
