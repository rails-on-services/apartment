# frozen_string_literal: true

namespace :apartment do
  desc 'Create all tenant schemas/databases from tenants_provider'
  task create: :environment do
    tenants = Apartment.config.tenants_provider.call
    tenants.each do |tenant|
      puts "Creating tenant: #{tenant}"
      Apartment::Tenant.create(tenant)
    rescue Apartment::TenantExists
      puts '  already exists, skipping'
    rescue StandardError => e
      warn "  FAILED: #{e.message}"
    end
  end

  desc 'Drop a tenant schema/database'
  task :drop, [:tenant] => :environment do |_t, args|
    abort 'Usage: rake apartment:drop[tenant_name]' unless args[:tenant]
    Apartment::Tenant.drop(args[:tenant])
    puts "Dropped tenant: #{args[:tenant]}"
  end

  desc 'Run migrations for all tenants'
  task migrate: :environment do
    require 'apartment/migrator'

    threads = Apartment.config.parallel_migration_threads
    migration_db_config = Apartment.config.migration_db_config

    migrator = Apartment::Migrator.new(
      threads: threads,
      migration_db_config: migration_db_config
    )

    result = migrator.run
    puts result.summary

    unless result.success?
      abort "apartment:migrate failed for #{result.failed.size} tenant(s)"
    end

    # Schema dump (respects ActiveRecord.dump_schema_after_migration)
    if ActiveRecord.dump_schema_after_migration
      Rake::Task['db:schema:dump'].invoke if Rake::Task.task_defined?('db:schema:dump')
    end
  end

  desc 'Seed all tenants'
  task seed: :environment do
    tenants = Apartment.config.tenants_provider.call
    tenants.each do |tenant|
      puts "Seeding tenant: #{tenant}"
      Apartment::Tenant.seed(tenant)
    rescue StandardError => e
      warn "  FAILED: #{e.message}"
    end
  end

  desc 'Rollback migrations for all tenants'
  task :rollback, [:step] => :environment do |_t, args|
    step = (args[:step] || 1).to_i
    tenants = Apartment.config.tenants_provider.call
    tenants.each do |tenant|
      puts "Rolling back tenant: #{tenant} (#{step} step(s))"
      Apartment::Tenant.switch(tenant) do
        ActiveRecord::Base.connection_pool.migration_context.rollback(step)
      end
    rescue StandardError => e
      warn "  FAILED: #{e.message}"
    end
  end
end
