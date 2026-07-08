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
        return unless confirmed_destructive?(tenant)

        Apartment::Tenant.drop(tenant)
        say("Dropped tenant: #{tenant}") unless quiet?
      end

      desc 'list', 'List all tenants'
      def list
        Apartment.tenant_names.each { |t| say(t) }
      end

      desc 'current', 'Show current tenant'
      def current
        say(Apartment::Current.tenant || Apartment.config&.default_tenant || 'none')
      end

      private

      def create_single(tenant)
        say("Creating tenant: #{tenant}") unless quiet?
        Apartment::Tenant.create(tenant)
        say('  created') unless quiet?
      rescue Apartment::TenantExists
        say('  already exists, skipping') unless quiet?
      end

      def create_all
        tenants = Apartment.tenant_names
        failed = []
        tenants.each do |t|
          say("Creating tenant: #{t}") unless quiet?
          Apartment::Tenant.create(t)
          say('  created') unless quiet?
        rescue Apartment::TenantExists
          say('  already exists, skipping') unless quiet?
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

      # Whether the irreversible drop may proceed. --force / APARTMENT_FORCE=1
      # is the explicit opt-in. On a TTY we prompt [y/N]. In a non-interactive
      # context (deploy/cron/CI, binstub, rake) we cannot prompt: rather than
      # let Thor's yes? read EOF as "no" — a silent cancel that still exits 0 —
      # or block on $stdin.gets against an open-but-empty pipe, refuse loudly
      # with a non-zero exit. Centralizing it here (not in the rake wrapper)
      # covers every entry point uniformly. See issue #457.
      def confirmed_destructive?(tenant)
        return true if force?

        unless $stdin.tty?
          raise(Thor::Error,
                'apartment tenants drop is destructive and cannot prompt in a ' \
                'non-interactive context. Re-run with --force or APARTMENT_FORCE=1 to proceed.')
        end

        return true if yes?("Drop tenant '#{tenant}'? This cannot be undone. [y/N]")

        say('Cancelled.')
        false
      end

      def quiet?
        options[:quiet] || ENV['APARTMENT_QUIET'] == '1'
      end
    end
  end
end
