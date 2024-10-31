# frozen_string_literal: true

require 'yaml'

# rubocop:disable Metrics/AbcSize, Metrics/MethodLength

module Apartment
  module Test
    def self.config
      @config ||= YAML.safe_load(ERB.new(File.read('spec/config/database.yml')).result)
    end

    class Config
      class << self
        def database_config
          {
            'test' => send(:"#{database_engine}_config"),
          }
        end

        def rails_config
          Class.new(Rails::Application) do
            config.load_defaults(Rails::VERSION::STRING.to_f)
            config.eager_load = false
            config.active_support.deprecation = :log
            config.secret_key_base = 'test'
            config.database_configuration = database_config
            config.assets.enabled = false
          end
        end

        def init!
          Rails.application = rails_config
          Rails.application.initialize!

          ActiveRecord::Base.establish_connection(database_config['test'])

          # For SQLite in-memory, we need to load the schema immediately
          return unless database_engine == 'sqlite'

          load(Rails.root.join('db/schema.rb'))
        end

        private

        def database_engine
          ENV.fetch('DATABASE_ENGINE', 'postgresql')
        end

        def postgresql_config
          base_config = {
            'adapter' => 'postgresql',
            'database' => 'apartment_postgresql_test',
            'username' => 'postgres',
            'password' => 'postgres',
            'host' => ENV.fetch('DATABASE_HOST', 'localhost'),
            'port' => ENV.fetch('DATABASE_PORT', 5432),
            'min_messages' => 'WARNING',
            'schema_search_path' => 'public',
          }

          if defined?(JRUBY_VERSION)
            base_config.merge!(
              'adapter' => 'postgresql',
              'driver' => 'org.postgresql.Driver',
              'url' => 'jdbc:postgresql://localhost:5432/apartment_postgresql_test',
              'timeout' => 5000,
              'pool' => 5
            )
          end

          base_config
        end

        def mysql_config
          base_config = {
            'adapter' => 'mysql2',
            'database' => 'apartment_mysql_test',
            'username' => 'root',
            'password' => '',
            'host' => ENV.fetch('DATABASE_HOST', '127.0.0.1'),
            'port' => ENV.fetch('DATABASE_PORT', 3306),
            'min_messages' => 'WARNING',
          }

          if defined?(JRUBY_VERSION)
            base_config.merge!(
              'adapter' => 'mysql',
              'driver' => 'com.mysql.cj.jdbc.Driver',
              'url' => 'jdbc:mysql://localhost:3306/apartment_mysql_test',
              'timeout' => 5000,
              'pool' => 5
            )
          end

          base_config
        end

        def sqlite_config
          return {} if defined?(JRUBY_VERSION)

          {
            'adapter' => 'sqlite3',
            'database' => ':memory:',
            'pool' => 50,
            'timeout' => 5000,
            'variables' => {
              'journal_mode' => 'MEMORY',
              'temp_store' => 'MEMORY',
              'synchronous' => 'OFF',
            },
          }
        end
      end
    end
  end
end

# rubocop:enable Metrics/AbcSize, Metrics/MethodLength
