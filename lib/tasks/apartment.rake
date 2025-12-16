# frozen_string_literal: true

require 'apartment/migrator'
require 'apartment/tasks/task_helper'
require 'apartment/tasks/schema_dumper'
require 'parallel'

apartment_namespace = namespace(:apartment) do
  desc('Create all tenants')
  task(create: :environment) do
    Apartment::TaskHelper.warn_if_tenants_empty

    Apartment::TaskHelper.tenants.each do |tenant|
      Apartment::TaskHelper.create_tenant(tenant)
    end
  end

  desc('Drop all tenants')
  task(drop: :environment) do
    Apartment::TaskHelper.tenants.each do |tenant|
      puts("Dropping #{tenant} tenant")
      Apartment::Tenant.drop(tenant)
    rescue Apartment::TenantNotFound, ActiveRecord::NoDatabaseError => e
      puts e.message
    end
  end

  desc('Migrate all tenants')
  task(migrate: :environment) do
    Apartment::TaskHelper.warn_if_tenants_empty

    results = Apartment::TaskHelper.each_tenant do |tenant|
      Apartment::TaskHelper.migrate_tenant(tenant)
    end

    Apartment::TaskHelper.display_summary('Migration', results)

    # Dump schema after successful migrations
    if results.all?(&:success)
      Apartment::Tasks::SchemaDumper.dump_if_enabled
    else
      puts '[Apartment] Skipping schema dump due to migration failures'
    end

    # Exit with non-zero status if any tenant failed
    exit(1) if results.any? { |r| !r.success }
  end

  desc('Seed all tenants')
  task(seed: :environment) do
    Apartment::TaskHelper.warn_if_tenants_empty

    Apartment::TaskHelper.each_tenant do |tenant|
      Apartment::TaskHelper.create_tenant(tenant)
      puts("Seeding #{tenant} tenant")
      Apartment::Tenant.switch(tenant) do
        Apartment::Tenant.seed
      end
    rescue Apartment::TenantNotFound => e
      puts e.message
    end
  end

  desc('Rolls the migration back to the previous version (specify steps w/ STEP=n) across all tenants.')
  task(rollback: :environment) do
    Apartment::TaskHelper.warn_if_tenants_empty

    step = ENV.fetch('STEP', '1').to_i

    results = Apartment::TaskHelper.each_tenant do |tenant|
      puts("Rolling back #{tenant} tenant")
      Apartment::Migrator.rollback(tenant, step)
    end

    Apartment::TaskHelper.display_summary('Rollback', results)

    # Dump schema after successful rollback
    if results.all?(&:success)
      Apartment::Tasks::SchemaDumper.dump_if_enabled
    else
      puts '[Apartment] Skipping schema dump due to rollback failures'
    end

    exit(1) if results.any? { |r| !r.success }
  end

  namespace(:migrate) do
    desc('Runs the "up" for a given migration VERSION across all tenants.')
    task(up: :environment) do
      Apartment::TaskHelper.warn_if_tenants_empty

      version = ENV.fetch('VERSION', nil)&.to_i
      raise('VERSION is required') unless version

      results = Apartment::TaskHelper.each_tenant do |tenant|
        puts("Migrating #{tenant} tenant up")
        Apartment::Migrator.run(:up, tenant, version)
      end

      Apartment::TaskHelper.display_summary('Migrate Up', results)
      Apartment::Tasks::SchemaDumper.dump_if_enabled if results.all?(&:success)
      exit(1) if results.any? { |r| !r.success }
    end

    desc('Runs the "down" for a given migration VERSION across all tenants.')
    task(down: :environment) do
      Apartment::TaskHelper.warn_if_tenants_empty

      version = ENV.fetch('VERSION', nil)&.to_i
      raise('VERSION is required') unless version

      results = Apartment::TaskHelper.each_tenant do |tenant|
        puts("Migrating #{tenant} tenant down")
        Apartment::Migrator.run(:down, tenant, version)
      end

      Apartment::TaskHelper.display_summary('Migrate Down', results)
      Apartment::Tasks::SchemaDumper.dump_if_enabled if results.all?(&:success)
      exit(1) if results.any? { |r| !r.success }
    end

    desc('Rolls back the tenant one migration and re migrate up (options: STEP=x, VERSION=x).')
    task(:redo) do
      if ENV.fetch('VERSION', nil)
        apartment_namespace['migrate:down'].invoke
        apartment_namespace['migrate:up'].invoke
      else
        apartment_namespace['rollback'].invoke
        apartment_namespace['migrate'].invoke
      end
    end
  end
end
