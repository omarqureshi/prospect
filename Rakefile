require "rspec/core/rake_task"
RSpec::Core::RakeTask.new(:spec)
task default: :spec

desc "Typecheck the emitted TypeScript (needs npm install)"
task :tsc do
  sh "npx tsc -p spec/golden"
end
