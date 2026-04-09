# frozen_string_literal: true

begin
  require('bundler')
rescue StandardError
  'You must `gem install bundler` and `bundle install` to run rake tasks'
end
Bundler.setup
Bundler::GemHelper.install_tasks

require 'appraisal'

require 'rspec'
require 'rspec/core/rake_task'

RSpec::Core::RakeTask.new(spec: %w[db:load_credentials db:test:prepare]) do |spec|
  spec.pattern = 'spec/**/*_spec.rb'
  # spec.rspec_opts = '--order rand:47078'
end

namespace :spec do
  %i[tasks unit adapters integration].each do |type|
    RSpec::Core::RakeTask.new(type => :spec) do |spec|
      spec.pattern = "spec/#{type}/**/*_spec.rb"
    end
  end
end

desc 'Start an interactive console with Apartment loaded'
task :console do
  require 'pry'
  require 'apartment'
  ARGV.clear
  Pry.start
end

task default: :spec

namespace :db do
  namespace :test do
    desc 'Prepare test databases (v4: handled by CI workflow steps or manual setup)'
    task(:prepare) do
      # See spec/config/*.yml.erb for connection details.
    end
  end

  desc "copy sample database credential files over if real files don't exist"
  task :load_credentials do
    # If no DATABASE_ENGINE is specified, we default to sqlite so that a db config is generated
    db_engine = ENV.fetch('DATABASE_ENGINE', 'sqlite')

    next unless db_engine && %w[postgresql mysql sqlite].include?(db_engine)

    # Load and write spec db config
    db_config_string = ERB.new(File.read("spec/config/#{db_engine}.yml.erb")).result
    File.write('spec/config/database.yml', db_config_string)

    # Load and write dummy app db config
    db_config = YAML.safe_load(db_config_string)
    File.write('spec/dummy/config/database.yml', { test: db_config['connections'][db_engine] }.to_yaml)
  end
end
