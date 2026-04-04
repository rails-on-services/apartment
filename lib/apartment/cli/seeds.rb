# frozen_string_literal: true

require 'thor'

module Apartment
  class CLI < Thor
    class Seeds < Thor
      def self.exit_on_failure? = true

      desc 'seed [TENANT]', 'Seed tenant databases'
      long_desc <<~DESC
        Without arguments, seeds all tenants from tenants_provider.
        With a TENANT argument, seeds only that tenant.
      DESC
      def seed(tenant = nil)
        if tenant
          seed_single(tenant)
        else
          seed_all
        end
      end

      private

      def seed_single(tenant)
        say("Seeding tenant: #{tenant}")
        Apartment::Tenant.seed(tenant)
        say('  done')
      end

      def seed_all
        tenants = Apartment.config.tenants_provider.call
        failed = []
        tenants.each do |t|
          say("Seeding tenant: #{t}")
          Apartment::Tenant.seed(t)
          say('  done')
        rescue StandardError => e
          warn("  FAILED: #{e.message}")
          failed << t
        end
        return if failed.empty?

        raise(Thor::Error, "Seed failed for #{failed.size} tenant(s): #{failed.join(', ')}")
      end
    end
  end
end
