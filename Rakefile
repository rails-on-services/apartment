# frozen_string_literal: true

begin
  require 'bundler'
rescue StandardError
  'You must `gem install bundler` and `bundle install` to run rake tasks'
end
Bundler.setup
Bundler::GemHelper.install_tasks

require 'appraisal'

require 'rspec'
require 'rspec/core/rake_task'

RSpec::Core::RakeTask.new(spec: %w[db:load_db_credentials db:test:prepare]) do |spec|
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
    if ENV['DATABASE_ENGINE'] == 'postgresql'
      task prepare: %w[postgres:drop_db postgres:build_db]
    elsif ENV['DATABASE_ENGINE'] == 'mysql'
      task prepare: %w[mysql:drop_db mysql:build_db]
    elsif ENV['DATABASE_ENGINE'] == 'sqlite'
      task :prepare do
        puts 'No need to prepare sqlite3 database'
      end
    else
      task :prepare do
        puts 'No database engine specified, skipping db:test:prepare'
      end
    end
  end

  desc "copy sample database credential files over if real files don't exist"
  task :load_db_credentials do
    # If no DATABASE_ENGINE is specified, we default to sqlite so that a db config is generated
    db_engine = ENV.fetch('DATABASE_ENGINE', 'sqlite')

    next unless db_engine && %w[postgresql mysql sqlite].include?(db_engine)

    # Load and write spec db config
    db_config_string = ERB.new(File.read("spec/config/#{db_engine}.yml.erb")).result
    File.open('spec/config/database.yml', 'w') do |f|
      f.write(db_config_string)
    end

    # Load and write dummy app db config
    db_config = YAML.safe_load(db_config_string)
    File.open('spec/dummy/config/database.yml', 'w') do |f|
      f.write({ test: db_config['connections'][db_engine] }.to_yaml)
    end
  end
end

namespace :postgres do
  require 'active_record'
  require File.join(File.dirname(__FILE__), 'spec', 'support', 'config').to_s

  desc 'Build the PostgreSQL test databases'
  task :build_db do
    params = []
    params << '-E UTF8'
    params << pg_config['database']
    params << "-U#{pg_config['username']}"
    params << "-h#{pg_config['host']}" if pg_config['host']
    params << "-p#{pg_config['port']}" if pg_config['port']

    begin
      `createdb #{params.join(' ')}`
    rescue StandardError
      'test db already exists'
    end
    ActiveRecord::Base.establish_connection pg_config
    migrate
  end

  desc 'drop the PostgreSQL test database'
  task :drop_db do
    puts "dropping database #{pg_config['database']}"
    params = []
    params << pg_config['database']
    params << "-U#{pg_config['username']}"
    params << "-h#{pg_config['host']}" if pg_config['host']
    params << "-p#{pg_config['port']}" if pg_config['port']
    `dropdb #{params.join(' ')}`
  end
end

namespace :mysql do
  require 'active_record'
  require File.join(File.dirname(__FILE__), 'spec', 'support', 'config').to_s

  desc 'Build the MySQL test databases'
  task :build_db do
    params = []
    params << "-h #{my_config['host']}" if my_config['host']
    params << "-u #{my_config['username']}" if my_config['username']
    params << "-p#{my_config['password']}" if my_config['password']
    params << "--port #{my_config['port']}" if my_config['port']
    begin
      `mysqladmin #{params.join(' ')} create #{my_config['database']}`
    rescue StandardError
      'test db already exists'
    end
    ActiveRecord::Base.establish_connection my_config
    migrate
  end

  desc 'drop the MySQL test database'
  task :drop_db do
    puts "dropping database #{my_config['database']}"
    params = []
    params << "-h #{my_config['host']}" if my_config['host']
    params << "-u #{my_config['username']}" if my_config['username']
    params << "-p#{my_config['password']}" if my_config['password']
    params << "--port #{my_config['port']}" if my_config['port']
    `mysqladmin #{params.join(' ')} drop #{my_config['database']} --force`
  end
end

# TODO: clean this up
def config
  Apartment::Test.config['connections']
end

def pg_config
  config['postgresql']
end

def my_config
  config['mysql']
end

def migrate
  # TODO: Figure out if there is any other possibility that can/should be
  # passed here as the second argument for the migration context
  if ActiveRecord.version > '7.1'
    ActiveRecord::MigrationContext.new('spec/dummy/db/migrate').migrate
  else
    ActiveRecord::MigrationContext.new('spec/dummy/db/migrate', ActiveRecord::SchemaMigration).migrate
  end
end
