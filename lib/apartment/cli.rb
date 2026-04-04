# frozen_string_literal: true

require 'thor'
require_relative 'cli/tenants'
require_relative 'cli/migrations'
require_relative 'cli/seeds'
require_relative 'cli/pool'

module Apartment
  class CLI < Thor
    def self.exit_on_failure? = true

    register CLI::Tenants,    'tenants',    'tenants COMMAND',    'Tenant lifecycle commands'
    register CLI::Migrations, 'migrations', 'migrations COMMAND', 'Migration commands'
    register CLI::Seeds,      'seeds',      'seeds COMMAND',      'Seed commands'
    register CLI::Pool,       'pool',       'pool COMMAND',       'Connection pool commands'
  end
end
