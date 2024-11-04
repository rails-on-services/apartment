# frozen_string_literal: true

# spec/support/migration_helpers.rb

module MigrationHelpers
  def migrate_tenant(tenant_name)
    Apartment::Tenant.switch(tenant_name) do
      ActiveRecord::Migration.maintain_test_schema!
      ActiveRecord::Base.connection.migration_context.migrate
    end
  end

  def rollback_tenant(tenant_name, steps = 1)
    Apartment::Tenant.switch(tenant_name) do
      ActiveRecord::Migration.maintain_test_schema!
      ActiveRecord::Base.connection.migration_context.rollback(steps)
    end
  end
end
