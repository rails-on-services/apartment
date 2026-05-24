# frozen_string_literal: true

source 'https://rubygems.org'

gemspec

gem 'appraisal', '~> 2.5'
gem 'rack-test', require: false
gem 'rspec', '~> 3.10'
# Loaded only by spec/unit/rspec_rails_lifecycle_spec.rb (require: false keeps
# it out of the plain-RSpec suite). That spec pins the rspec-rails
# CurrentAttributes lifecycle that docs/testing.md depends on.
gem 'rspec-rails', '~> 8.0', require: false
# Provides Async::Scheduler — the Fiber::Scheduler implementation
# spec/integration/v4/fiber_safety_spec.rb's "Fiber.scheduler integration"
# context needs to actually run (MRI has no built-in concrete scheduler).
# Targets the fiber-based async path Rails apps use when running on a
# fiber-aware executor (e.g., Falcon); thread-based load_async tenant
# propagation is a separate concern.
gem 'async', '~> 2.0', require: false

group :development do
  gem 'rubocop', require: false
  gem 'rubocop-performance', require: false
  gem 'rubocop-rails', require: false
  gem 'rubocop-rake', require: false
  gem 'rubocop-rspec', require: false
  gem 'rubocop-thread_safety', require: false
end

group :development, :test do
  gem 'simplecov', require: false
  gem 'test-prof', require: false
end
