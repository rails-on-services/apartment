# frozen_string_literal: true

require('tmpdir')
require('fileutils')
require('erb')
require('yaml')

# Integration tests require real ActiveRecord + a database gem.
# Run via appraisal:
#   bundle exec appraisal rails-8.1-sqlite3      rspec spec/integration/v4/
#   bundle exec appraisal rails-8.1-postgresql    rspec spec/integration/v4/
#   bundle exec appraisal rails-8.1-mysql2        rspec spec/integration/v4/
#
# Set DATABASE_ENGINE to force an engine: postgresql, mysql, sqlite (default: sqlite)
V4_INTEGRATION_AVAILABLE = begin
  require('active_record')
  ActiveRecord::Base.respond_to?(:establish_connection)
rescue LoadError
  false
end

# Helpers for multi-engine integration tests.
module V4IntegrationHelper
  module_function

  def database_engine
    ENV.fetch('DATABASE_ENGINE', 'sqlite')
  end

  def postgresql?
    database_engine == 'postgresql'
  end

  def mysql?
    database_engine == 'mysql'
  end

  def sqlite?
    database_engine == 'sqlite'
  end

  # Establish the default AR connection for the current engine.
  # Returns the connection config hash (string keys).
  def establish_default_connection!(tmp_dir: nil)
    config = default_connection_config(tmp_dir: tmp_dir)
    ActiveRecord::Base.establish_connection(config)
    config
  end

  # Build the default connection config for the current engine.
  def default_connection_config(tmp_dir: nil)
    case database_engine
    when 'postgresql'
      {
        'adapter' => 'postgresql',
        'host' => ENV.fetch('PGHOST', '127.0.0.1'),
        'port' => ENV.fetch('PGPORT', '5432').to_i,
        'username' => ENV.fetch('PGUSER', ENV.fetch('USER', nil)),
        'password' => ENV.fetch('PGPASSWORD', nil),
        'database' => ENV.fetch('APARTMENT_TEST_PG_DB', 'apartment_v4_test'),
      }
    when 'mysql'
      {
        'adapter' => 'mysql2',
        'host' => ENV.fetch('MYSQL_HOST', '127.0.0.1'),
        'port' => ENV.fetch('MYSQL_PORT', '3306').to_i,
        'username' => ENV.fetch('MYSQL_USER', 'root'),
        'password' => ENV.fetch('MYSQL_PASSWORD', nil),
        'database' => ENV.fetch('APARTMENT_TEST_MYSQL_DB', 'apartment_v4_test'),
      }
    else # sqlite
      {
        'adapter' => 'sqlite3',
        'database' => File.join(tmp_dir || Dir.mktmpdir('apartment_v4'), 'default.sqlite3'),
      }
    end
  end

  # Build the v4 adapter for the current engine.
  def build_adapter(connection_config)
    case database_engine
    when 'postgresql'
      require('apartment/adapters/postgresql_schema_adapter')
      Apartment::Adapters::PostgresqlSchemaAdapter.new(connection_config.transform_keys(&:to_sym))
    when 'mysql'
      require('apartment/adapters/mysql2_adapter')
      Apartment::Adapters::Mysql2Adapter.new(connection_config.transform_keys(&:to_sym))
    else
      require('apartment/adapters/sqlite3_adapter')
      Apartment::Adapters::Sqlite3Adapter.new(connection_config.transform_keys(&:to_sym))
    end
  end

  # The tenant strategy for the current engine.
  def tenant_strategy
    postgresql? ? :schema : :database_name
  end

  # The default tenant name (PG schema strategy uses 'public').
  def default_tenant
    postgresql? ? 'public' : 'default'
  end

  # Create a test table in the current connection.
  def create_test_table!(table_name = 'widgets', connection: ActiveRecord::Base.connection)
    connection.create_table(table_name, force: true) do |t|
      t.string(:name)
    end
  end

  # Ensure the test database exists for PG/MySQL (no-op for SQLite).
  def ensure_test_database!
    case database_engine
    when 'postgresql'
      db_name = ENV.fetch('APARTMENT_TEST_PG_DB', 'apartment_v4_test')
      # Connect to 'postgres' DB to create the test DB
      ActiveRecord::Base.establish_connection(
        default_connection_config.merge('database' => 'postgres')
      )
      unless ActiveRecord::Base.connection.select_value(
        "SELECT 1 FROM pg_database WHERE datname = '#{db_name}'"
      )
        ActiveRecord::Base.connection.execute("CREATE DATABASE #{db_name}")
      end
      ActiveRecord::Base.establish_connection(default_connection_config)
    when 'mysql'
      db_name = ENV.fetch('APARTMENT_TEST_MYSQL_DB', 'apartment_v4_test')
      # Connect without a database to create it
      ActiveRecord::Base.establish_connection(
        default_connection_config.merge('database' => nil)
      )
      ActiveRecord::Base.connection.execute("CREATE DATABASE IF NOT EXISTS `#{db_name}`")
      ActiveRecord::Base.establish_connection(default_connection_config)
    end
    # SQLite: no-op, file created on connect
  end

  # Drop tenant schemas/databases created during tests.
  def cleanup_tenants!(tenant_names, adapter)
    tenant_names.each do |tenant|
      adapter.drop(tenant)
    rescue StandardError => e
      warn "[V4IntegrationHelper] cleanup_tenants! failed for '#{tenant}': #{e.message}"
    end
  end

  # --- Scenario-based configs ---

  Scenario = Struct.new(:name, :engine, :strategy, :adapter_class, :default_tenant,
                        :connection)

  def load_scenario(name)
    path = File.join(__dir__, 'scenarios', "#{name}.yml")
    raise(ArgumentError, "Scenario file not found: #{path}") unless File.exist?(path)

    raw = YAML.safe_load(ERB.new(File.read(path)).result, permitted_classes: [Symbol])
    Scenario.new(
      name: raw['name'],
      engine: raw['engine'],
      strategy: raw['strategy'].to_sym,
      adapter_class: raw['adapter_class'],
      default_tenant: raw['default_tenant'],
      connection: raw['connection'].transform_keys(&:to_s)
    )
  end

  def scenarios_for_engine
    Dir[File.join(__dir__, 'scenarios', '*.yml')].filter_map do |path|
      scenario_name = File.basename(path, '.yml')
      scenario = load_scenario(scenario_name)
      scenario if scenario.engine == database_engine
    end
  end

  def each_scenario(&)
    scenarios_for_engine.each(&)
  end
end

if V4_INTEGRATION_AVAILABLE
  RSpec.configure do |config|
    # Swap ConnectionHandler per test for hermetic isolation.
    # Skip for :stress-tagged tests — concurrent threads race with handler swap teardown.
    config.around(:each, :integration) do |example|
      if example.metadata[:stress]
        example.run
        next
      end

      old_handler = ActiveRecord::Base.connection_handler
      new_handler = ActiveRecord::ConnectionAdapters::ConnectionHandler.new
      ActiveRecord::Base.connection_handler = new_handler

      # Re-establish the default connection on the fresh handler.
      default_config = V4IntegrationHelper.default_connection_config
      ActiveRecord::Base.establish_connection(default_config) if default_config

      example.run
    ensure
      unless example.metadata[:stress]
        begin
          new_handler&.clear_all_connections!
        rescue StandardError => e
          warn "[V4IntegrationHelper] clear_all_connections! failed: #{e.message}"
        end
        ActiveRecord::Base.connection_handler = old_handler
      end
    end
  end
end
