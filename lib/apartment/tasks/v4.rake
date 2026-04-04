# frozen_string_literal: true

require 'apartment/cli'

namespace :apartment do
  desc 'Create all tenant schemas/databases (or one: rake apartment:create[tenant])'
  task :create, [:tenant] => :environment do |_t, args|
    if args[:tenant]
      Apartment::CLI::Tenants.new.invoke(:create, [args[:tenant]])
    else
      Apartment::CLI::Tenants.new.invoke(:create)
    end
  end

  desc 'Drop a tenant schema/database'
  task :drop, [:tenant] => :environment do |_t, args|
    abort('Usage: rake apartment:drop[tenant_name]') unless args[:tenant]
    Apartment::CLI::Tenants.new.invoke(:drop, [args[:tenant]], force: true)
  end

  desc 'Run migrations for all tenants (or one: rake apartment:migrate[tenant])'
  task :migrate, [:tenant] => :environment do |_t, args|
    if args[:tenant]
      Apartment::CLI::Migrations.new.invoke(:migrate, [args[:tenant]])
    else
      Apartment::CLI::Migrations.new.invoke(:migrate)
    end
  end

  desc 'Seed all tenants'
  task seed: :environment do
    Apartment::CLI::Seeds.new.invoke(:seed)
  end

  desc 'Rollback migrations for all tenants'
  task :rollback, [:step] => :environment do |_t, args|
    Apartment::CLI::Migrations.new.invoke(:rollback, [], step: (args[:step] || 1).to_i)
  end

  namespace :schema do
    namespace :cache do
      desc 'Dump schema cache for each tenant'
      task dump: :environment do
        require 'apartment/schema_cache'
        paths = Apartment::SchemaCache.dump_all
        paths.each { |p| puts("Dumped: #{p}") }
      end
    end
  end
end
