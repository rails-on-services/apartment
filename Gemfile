# frozen_string_literal: true

source 'http://rubygems.org'

gem 'appraisal', '~> 2.3'
gem 'rake', '< 14.0'

group :test do
  gem 'database_cleaner-active_record'

  gem 'faker'

  gem 'rspec', '~> 3.10'
  gem 'rspec_junit_formatter', '~> 0.4'
  gem 'rspec-rails', '>= 6.1.0', '< 8.1'

  gem 'rubocop', '~> 1.12', require: false
  gem 'rubocop-performance', '~> 1.10', require: false
  gem 'rubocop-rails', '~> 2.10', require: false
  gem 'rubocop-rake', '~> 0.5', require: false
  gem 'rubocop-rspec', '~> 3.1', require: false
  gem 'rubocop-thread_safety', '~> 0.4', require: false
  gem 'simplecov', require: false
end

group :development do
  # IRB alternative console
  gem 'pry'
  # Make pry the default console
  gem 'pry-rails'
  # adds docs to the pry CLI
  gem 'pry-doc'
end

gemspec
