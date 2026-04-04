# frozen_string_literal: true

require 'thor'

module Apartment
  class CLI < Thor
    class Tenants < Thor
      def self.exit_on_failure? = true

      desc 'create [TENANT]', 'Create tenant schema/database'
      long_desc <<~DESC
        Without arguments, creates all tenants returned by tenants_provider.
        With a TENANT argument, creates only that tenant.
        Skips tenants that already exist (no error).
      DESC
      method_option :quiet, type: :boolean, desc: 'Suppress per-tenant output'
      def create(tenant = nil)
        if tenant
          create_single(tenant)
        else
          create_all
        end
      end

      desc 'drop TENANT', 'Drop a tenant schema/database'
      long_desc <<~DESC
        Drops the specified tenant. Requires confirmation unless --force is set.
        There is no "drop all" — this is intentionally a single-tenant operation.
      DESC
      method_option :force, type: :boolean, desc: 'Skip confirmation prompt'
      def drop(tenant)
        unless force?
          return say('Cancelled.') unless yes?("Drop tenant '#{tenant}'? This cannot be undone. [y/N]")
        end

        Apartment::Tenant.drop(tenant)
        say("Dropped tenant: #{tenant}") unless quiet?
      end

      desc 'list', 'List all tenants'
      def list
        Apartment.config.tenants_provider.call.each { |t| say(t) }
      end

      desc 'current', 'Show current tenant'
      def current
        say(Apartment::Current.tenant || Apartment.config&.default_tenant || 'none')
      end

      private

      def create_single(tenant)
        say("Creating tenant: #{tenant}") unless quiet?
        Apartment::Tenant.create(tenant)
        say("  created") unless quiet?
      rescue Apartment::TenantExists
        say("  already exists, skipping") unless quiet?
      end

      def create_all
        tenants = Apartment.config.tenants_provider.call
        failed = []
        tenants.each do |t|
          say("Creating tenant: #{t}") unless quiet?
          Apartment::Tenant.create(t)
          say("  created") unless quiet?
        rescue Apartment::TenantExists
          say("  already exists, skipping") unless quiet?
        rescue StandardError => e
          warn("  FAILED: #{e.message}")
          failed << t
        end
        return if failed.empty?

        raise(Thor::Error, "apartment tenants create failed for #{failed.size} tenant(s): #{failed.join(', ')}")
      end

      def force?
        options[:force] || ENV['APARTMENT_FORCE'] == '1'
      end

      def quiet?
        options[:quiet] || ENV['APARTMENT_QUIET'] == '1'
      end
    end
  end
end
