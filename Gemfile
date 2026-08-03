source "https://rubygems.org"
gemspec

group :development, :test do
  gem "rake"
  # Only the authorizer needs it, and only at runtime in its own unit.
  gem "jwt", "~> 3.1"
  gem "rspec", "~> 3.13"
  # Not a default gem since Ruby 3.4. Prospect matches BigDecimal by class
  # NAME, so it needs no runtime dependency — but the fixture instantiates one.
  gem "bigdecimal"
end

# Optional: only needed to run the CDK specs. Pulls in jsii and a Node sidecar,
# which is why prospect/cdk is a separate require and not loaded by default.
group :cdk do
  source "https://rubygems.omarqureshi.net" do
    gem "aws-cdk-lib", ">= 0.0.0.pre"
    gem "constructs", ">= 0.0.0.pre"
    gem "jsii-ruby-runtime", ">= 0.0.0.pre"
    gem "aws-cdk-asset-awscli-v1", ">= 0.0.0.pre"
    gem "aws-cdk-asset-node-proxy-agent-v6", ">= 0.0.0.pre"
    gem "aws-cdk-cloud-assembly-schema", ">= 0.0.0.pre"
  end
end
