source "https://rubygems.org"
gemspec

group :development, :test do
  gem "rake"
  gem "rspec", "~> 3.13"
  # Not a default gem since Ruby 3.4. Prospect matches BigDecimal by class
  # NAME, so it needs no runtime dependency — but the fixture instantiates one.
  gem "bigdecimal"
end
