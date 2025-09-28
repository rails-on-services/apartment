# frozen_string_literal: true

begin
  require('bundler')
rescue StandardError
  'You must `gem install bundler` and `bundle install` to run rake tasks'
end
Bundler.setup
Bundler::GemHelper.install_tasks

require 'appraisal'
require 'yaml'

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

task :console do
  require 'pry'
  require 'apartment'
  ARGV.clear
  Pry.start
end

task default: :spec

namespace :db do
  namespace :test do
    case ENV.fetch('DATABASE_ENGINE', nil)
    when 'postgresql'
      task(prepare: %w[postgres:drop_db postgres:build_db])
    when 'mysql'
      task(prepare: %w[mysql:drop_db mysql:build_db])
    when 'sqlite'
      task(:prepare) do
        puts 'No need to prepare sqlite3 database'
      end
    else
      task(:prepare) do
        puts 'No database engine specified, skipping db:test:prepare'
      end
    end
  end
end

namespace :postgres do
  desc 'Build the PostgreSQL test databases'
  task :build_db do
    params = []
    params << '-E UTF8'
    params << db_config['database']
    params << "-U #{db_config['username']}" if db_config['username']
    params << "-h #{db_config['host']}" if db_config['host']
    params << "-p #{db_config['port']}" if db_config['port']
    if system("createdb #{params.join(' ')}")
      puts "Created database #{db_config['database']}"
    else
      puts 'Create failed. Does it already exist?'
    end
  end

  desc 'drop the PostgreSQL test database'
  task :drop_db do
    puts "Dropping database #{db_config['database']}"
    params = []
    params << db_config['database']
    params << "-U #{db_config['username']}" if db_config['username']
    params << "-h #{db_config['host']}" if db_config['host']
    params << "-p #{db_config['port']}" if db_config['port']
    system("dropdb #{params.join(' ')}")
  end
end

namespace :mysql do
  desc 'Build the MySQL test databases'
  task :build_db do
    params = []
    params << "-h #{db_config['host']}" if db_config['host']
    params << "-u #{db_config['username']}" if db_config['username']
    params << "-p #{db_config['password']}" if db_config['password']
    params << "-P #{db_config['port']}" if db_config['port']

    if system("mysqladmin #{params.join(' ')} create #{db_config['database']}")
      puts "Created database #{db_config['database']}"
    else
      puts 'Create failed. Does it already exist?'
    end
  end

  desc 'drop the MySQL test database'
  task :drop_db do
    puts "Dropping database #{db_config['database']}"
    params = []
    params << "-h #{db_config['host']}" if db_config['host']
    params << "-u #{db_config['username']}" if db_config['username']
    params << "-p #{db_config['password']}" if db_config['password']
    params << "-P #{db_config['port']}" if db_config['port']
    system("mysqladmin #{params.join(' ')} drop #{db_config['database']} --force")
  end
end

def db_config
  @db_config ||= YAML.safe_load(ERB.new(File.read('spec/dummy/config/database.yml')).result, aliases: true)['test']
end
