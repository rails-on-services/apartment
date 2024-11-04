# frozen_string_literal: true

# spec/support/database_helpers.rb

module DatabaseHelpers
  def tenant_exists?(name)
    case database_adapter
    when 'postgresql'
      tenant_exists_postgresql?(name)
    when 'mysql2', 'trilogy'
      tenant_exists_mysql?(name)
    when 'sqlite3'
      tenant_exists_sqlite?(name)
    else
      raise("Adapter #{database_adapter} not supported in tests yet")
    end
  end

  def create_tenant_schema(name, check_if_exists: true)
    raise(Apartment::TenantExists) if check_if_exists && tenant_exists?(name)

    if use_postgres?
      create_postgresql_schema(name)
    else
      Apartment::Tenant.create(name)
    end
  end

  def drop_tenant_schema(name, adapter = nil)
    adapter.switch(nil) # Reset to default first

    if use_postgres?
      drop_postgresql_schema(name)
    elsif adapter
      adapter.drop(name)
    else
      Apartment::Tenant.drop(name)
    end
  rescue Apartment::TenantNotFound
    # It's fine if tenant doesn't exist during cleanup
  end

  def generate_tenant_name(check_if_exists: true)
    retries = 0
    max_retries = 3

    while retries < max_retries
      candidate = generate_candidate_name(retries)

      return candidate unless check_if_exists && tenant_exists?(candidate)

      retries += 1
    end

    # Fallback if we couldn't generate a unique name using Faker
    "tenant_#{SecureRandom.hex(6)}"
  end

  protected

  def database_adapter
    Apartment.connection_class.connection.adapter_name.downcase
  end

  def use_postgres?
    database_adapter == 'postgresql'
  end

  private

  def generate_candidate_name(retries)
    candidate = case retries
                when 0
                  Faker::Internet.unique.domain_word
                when 1
                  Faker::App.unique.name.downcase.gsub(/[^a-z0-9]/, '_')
                else
                  "tenant_#{Faker::Internet.unique.slug(words_separator: '_')}"
                end

    # Ensure name starts with letter and contains only allowed characters
    candidate = "t_#{candidate}" unless candidate.match?(/^[a-z]/i)
    candidate.gsub(/[^a-z0-9_]/, '_').squeeze('_')
  end

  def tenant_exists_postgresql?(name)
    if Apartment.use_schemas
      Apartment.connection.schema_exists?(name.to_s)
    else
      Apartment.connection.execute(
        "SELECT 1 FROM pg_database WHERE datname = '#{name}'"
      ).any?
    end
  end

  def tenant_exists_mysql?(name)
    Apartment.connection.execute(
      "SELECT 1 FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME = '#{name}'"
    ).any?
  end

  def tenant_exists_sqlite?(name)
    connection = ActiveRecord::Base.connection
    adapter = Apartment::Tenant.adapter

    adapter.switch(name) do
      expected_tables = %w[users companies]
      existing_tables = connection.tables
      (expected_tables - existing_tables).empty?
    end
  end

  def create_postgresql_schema(name)
    Apartment.connection.execute("CREATE SCHEMA #{name}")
  end

  def drop_postgresql_schema(name)
    Apartment.connection.execute("DROP SCHEMA IF EXISTS #{name} CASCADE")
  end
end
