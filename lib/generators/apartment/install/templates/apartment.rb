# frozen_string_literal: true

Apartment.configure do |config|
  # == Required ===========================================================

  # Tenant isolation strategy.
  #   :schema         - PostgreSQL schemas (one schema per tenant, single DB)
  #   :database_name  - Separate database per tenant (MySQL, PostgreSQL)
  config.tenant_strategy = :schema

  # Returns an array of tenant identifiers. Called at runtime by migrate,
  # create, seed, and other bulk operations.
  config.tenants_provider = -> { raise('TODO: replace with e.g. Account.pluck(:subdomain)') }

  # == Tenant Defaults =====================================================

  # The default tenant (used on boot and between requests).
  # config.default_tenant = 'public'

  # Models that live in the shared/default schema (not per-tenant).
  # config.excluded_models = %w[Account]

  # == Connection Pool =====================================================

  # config.tenant_pool_size      = 5
  # config.pool_idle_timeout     = 300
  # config.max_total_connections = nil

  # == Elevator (Request Tenant Detection) =================================

  # The Railtie auto-inserts the elevator as middleware.
  # No manual insertion into config.middleware is needed.
  #
  # config.elevator = :subdomain
  # config.elevator_options = {}

  # == Migrations ==========================================================

  # config.parallel_migration_threads = 0
  # config.schema_load_strategy       = nil  # :schema_rb or :sql
  # config.seed_after_create           = false
  # config.check_pending_migrations    = true

  # == RBAC & Roles =========================================================

  # config.migration_role          = nil   # e.g. :db_manager (Phase 5 role-aware connections)
  # config.app_role                = nil   # e.g. 'app_role' or -> { "app_#{Rails.env}" }
  # config.environmentify_strategy = nil   # nil, :prepend, :append, or a callable

  # == PostgreSQL ===========================================================

  # config.configure_postgres do |pg|
  #   pg.persistent_schemas = %w[shared extensions]
  # end

  # == MySQL ================================================================

  # config.configure_mysql do |my|
  # end
end
