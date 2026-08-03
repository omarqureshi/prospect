# frozen_string_literal: true

# Kept dependency-free and separate from lib/prospect.rb on purpose: the gemspec
# reads the version, and requiring the full library there would need every
# runtime dependency present before `bundle install` has resolved them.
module Prospect
  VERSION = "0.0.2"
end
