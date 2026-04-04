# frozen_string_literal: true

require 'thor'

module Apartment
  class CLI < Thor
    class Pool < Thor
      def self.exit_on_failure? = true

      desc 'stats', 'Show connection pool statistics'
      long_desc <<~DESC
        Displays pool summary: total pools and tenant list.
        With --verbose, shows per-tenant idle time.
      DESC
      method_option :verbose, type: :boolean, desc: 'Per-tenant breakdown'
      def stats
        unless Apartment.pool_manager
          say('Apartment is not configured. Run Apartment.configure first.')
          return
        end

        pool_stats = Apartment.pool_manager.stats
        say("Total pools: #{pool_stats[:total_pools]}")

        if options[:verbose] && pool_stats[:tenants]&.any?
          say("\nPer-tenant details:")
          pool_stats[:tenants].each do |tenant_key|
            tenant_stats = Apartment.pool_manager.stats_for(tenant_key)
            idle = tenant_stats ? "#{tenant_stats[:seconds_idle].round(1)}s idle" : 'unknown'
            say("  #{tenant_key}: #{idle}")
          end
        elsif pool_stats[:tenants]&.any?
          say("Tenants: #{pool_stats[:tenants].join(', ')}")
        end
      end

      desc 'evict', 'Force idle pool eviction'
      long_desc <<~DESC
        Triggers one synchronous eviction cycle (idle + LRU).
        Requires confirmation unless --force is set.
      DESC
      method_option :force, type: :boolean, desc: 'Skip confirmation prompt'
      def evict
        unless Apartment.pool_reaper
          say('Apartment is not configured. Run Apartment.configure first.')
          return
        end

        unless force?
          return say('Cancelled.') unless yes?('Run pool eviction cycle? [y/N]')
        end

        count = Apartment.pool_reaper.run_cycle
        say("Evicted #{count} pool(s).")
      end

      private

      def force?
        options[:force] || ENV['APARTMENT_FORCE'] == '1'
      end
    end
  end
end
