# frozen_string_literal: true

source 'http://rubygems.org'

gem 'appraisal', '>= 2.5', require: false
gem 'rake', '>= 13.2'

group :test do
  gem 'database_cleaner-active_record'

  gem 'faker'

  gem 'rspec', '>= 3.13'
  gem 'rspec_junit_formatter', '>= 0.6'
  gem 'rspec-rails', '>= 7.0'

  gem 'rubocop', '>= 1.68', require: false
  gem 'rubocop-performance', '>= 1.22', require: false
  gem 'rubocop-rails', '>= 2.27', require: false
  gem 'rubocop-rake', '>= 0.6', require: false
  gem 'rubocop-rspec', '>= 3.2', require: false
  gem 'rubocop-thread_safety', '>= 0.6', require: false
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
