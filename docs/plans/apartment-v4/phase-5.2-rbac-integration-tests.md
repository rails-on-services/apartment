# Phase 5.2: RBAC Integration Tests — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Integration tests that verify Phase 5's role-aware connections, RBAC privilege grants, and Migrator migration_role against real PostgreSQL roles and MySQL users.

**Architecture:** RbacHelper module provides engine-aware role provisioning, `connect_as` for grant tests (separate connections), and `setup_connects_to!` for role-aware routing tests (real AR role wiring). CI provisions roles via psql/mysql steps; local dev falls back to idempotent `before(:context)` hooks. All specs tagged `:rbac` + engine tag, auto-skip when roles unavailable.

**Tech Stack:** RSpec, ActiveRecord (PostgreSQL pg adapter, mysql2 adapter), GitHub Actions CI

**Spec:** `docs/designs/v4-phase5.2-rbac-integration-tests.md`

---

## File Map

```
.github/workflows/ci.yml                              # MODIFY — add RBAC role provisioning steps
spec/integration/v4/
  support/
    rbac_helper.rb                                     # NEW — shared RBAC test infrastructure
  role_aware_connection_spec.rb                        # NEW — ConnectionHandling role-based pool resolution
  rbac_grants_spec.rb                                  # NEW — PG privilege boundary verification
  migrator_rbac_spec.rb                                # NEW — Migrator with migration_role
  mysql_rbac_grants_spec.rb                            # NEW — MySQL privilege boundary verification
```

---

### Task 1: CI Role Provisioning

**Files:**
- Modify: `.github/workflows/ci.yml:89-102` (PG job steps), `:133-145` (MySQL job steps)

- [ ] **Step 1: Add PostgreSQL role provisioning step**

In `.github/workflows/ci.yml`, insert a new step in the `postgresql` job between the `ruby/setup-ruby` step and the "Run v4 integration tests" step (after line 94, before line 95):

```yaml
      - name: Provision RBAC test roles
        run: |
          psql -h 127.0.0.1 -U postgres -d apartment_postgresql_test <<'SQL'
            DO $$
            BEGIN
              IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'apt_test_db_manager') THEN
                CREATE ROLE apt_test_db_manager LOGIN CREATEDB;
              END IF;
              IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'apt_test_app_user') THEN
                CREATE ROLE apt_test_app_user LOGIN;
              END IF;
            END $$;
            GRANT apt_test_app_user TO apt_test_db_manager;
          SQL
```

- [ ] **Step 2: Add MySQL role provisioning step**

In `.github/workflows/ci.yml`, insert a new step in the `mysql` job between the `ruby/setup-ruby` step and the "Run v4 integration tests" step (after line 138, before line 139):

```yaml
      - name: Provision RBAC test roles
        run: |
          mysql -h 127.0.0.1 -u root <<'SQL'
            CREATE USER IF NOT EXISTS 'apt_test_db_manager'@'%';
            CREATE USER IF NOT EXISTS 'apt_test_app_user'@'%';
            GRANT ALL PRIVILEGES ON *.* TO 'apt_test_db_manager'@'%';
            GRANT SELECT, INSERT, UPDATE, DELETE ON `apartment\_%`.* TO 'apt_test_app_user'@'%';
            FLUSH PRIVILEGES;
          SQL
```

Note: No `-p` flag — CI MySQL uses `MYSQL_ALLOW_EMPTY_PASSWORD: 'yes'`.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: add RBAC test role provisioning for PG and MySQL"
```

---

### Task 2: RbacHelper Module

**Files:**
- Create: `spec/integration/v4/support/rbac_helper.rb`

- [ ] **Step 1: Create the rbac_helper.rb file**

```ruby
# frozen_string_literal: true

# Shared RBAC test infrastructure for integration tests that verify
# role-aware connections, privilege grants, and Migrator migration_role.
#
# Usage: tag specs with :rbac plus :postgresql_only or :mysql_only.
# Roles are provisioned once per suite via before(:context, :rbac).
# If provisioning fails (e.g., local PG user lacks CREATEROLE),
# all :rbac specs skip with an actionable message.
module RbacHelper
  ROLES = {
    db_manager: 'apt_test_db_manager',
    app_user: 'apt_test_app_user'
  }.freeze

  @provisioned = false
  @available = false

  module_function

  def provisioned?
    @provisioned
  end

  def available?
    @available
  end

  # Idempotent role creation. Engine-aware.
  # Returns true on success, false on failure.
  def provision_roles!(connection)
    return @available if @provisioned

    @provisioned = true
    engine = V4IntegrationHelper.database_engine

    case engine
    when 'postgresql'
      provision_pg_roles!(connection)
    when 'mysql'
      provision_mysql_roles!(connection)
    else
      warn '[RbacHelper] RBAC tests require PostgreSQL or MySQL'
      return(@available = false)
    end

    @available = true
  rescue ActiveRecord::StatementInvalid => e
    warn "[RbacHelper] Could not provision roles (#{e.class}): #{e.message}"
    warn '[RbacHelper] See docs/designs/v4-phase5.2-rbac-integration-tests.md for setup instructions.'
    @available = false
  end

  # Connect as a specific role. Stashes the original config for restoration.
  # For grant verification tests (separate connections, not SET ROLE).
  def connect_as(role_key)
    username = ROLES.fetch(role_key)
    @stashed_config ||= ActiveRecord::Base.connection_db_config.configuration_hash.stringify_keys
    ActiveRecord::Base.establish_connection(@stashed_config.merge('username' => username))
  end

  # Restore the connection stashed by connect_as.
  def restore_default_connection!
    return unless @stashed_config

    ActiveRecord::Base.establish_connection(@stashed_config)
    @stashed_config = nil
  end

  # Register database configs for :writing and :db_manager roles with AR's
  # ConnectionHandler. Uses the same database but different usernames.
  # Call in before(:each) — after the ConnectionHandler swap creates a fresh handler.
  def setup_connects_to!(base_config)
    handler = ActiveRecord::Base.connection_handler

    { writing: base_config,
      db_manager: base_config.merge('username' => ROLES[:db_manager]) }.each do |role, config|
      db_config = ActiveRecord::DatabaseConfigurations::HashConfig.new(
        'test', "primary_#{role}", config
      )
      handler.establish_connection(
        db_config,
        owner_name: ActiveRecord::Base,
        role: role
      )
    end
  end

  # Disconnect and remove non-primary pools created during tests.
  def teardown_rbac_connections!
    @stashed_config = nil
  end

  # --- Private provisioning methods ---

  def provision_pg_roles!(connection)
    connection.execute(<<~SQL)
      DO $$
      BEGIN
        IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '#{ROLES[:db_manager]}') THEN
          CREATE ROLE #{ROLES[:db_manager]} LOGIN CREATEDB;
        END IF;
        IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '#{ROLES[:app_user]}') THEN
          CREATE ROLE #{ROLES[:app_user]} LOGIN;
        END IF;
      END $$;
    SQL
    connection.execute("GRANT #{ROLES[:app_user]} TO #{ROLES[:db_manager]}")
    # GRANT CREATE ON DATABASE so db_manager can create schemas.
    # This runs here (not in CI provisioning) because the test database
    # (apartment_v4_test) may not exist at CI role-provisioning time.
    db_name = connection.current_database
    connection.execute("GRANT CREATE ON DATABASE #{connection.quote_table_name(db_name)} TO #{ROLES[:db_manager]}")
  end

  def provision_mysql_roles!(connection)
    connection.execute("CREATE USER IF NOT EXISTS '#{ROLES[:db_manager]}'@'%'")
    connection.execute("CREATE USER IF NOT EXISTS '#{ROLES[:app_user]}'@'%'")
    connection.execute("GRANT ALL PRIVILEGES ON *.* TO '#{ROLES[:db_manager]}'@'%'")
    connection.execute(
      "GRANT SELECT, INSERT, UPDATE, DELETE ON `apartment\\_%`.* TO '#{ROLES[:app_user]}'@'%'"
    )
    connection.execute('FLUSH PRIVILEGES')
  end

  private_class_method :provision_pg_roles!, :provision_mysql_roles!
end

# Wire up the :rbac tag to provision roles once per context.
if V4_INTEGRATION_AVAILABLE
  RSpec.configure do |config|
    config.before(:context, :rbac) do
      V4IntegrationHelper.ensure_test_database!
      V4IntegrationHelper.establish_default_connection!

      unless RbacHelper.provision_roles!(ActiveRecord::Base.connection)
        skip 'RBAC test roles not available. See docs/designs/v4-phase5.2-rbac-integration-tests.md'
      end
    end
  end
end
```

- [ ] **Step 2: Verify file loads without error**

```bash
bundle exec ruby -e "
  require 'active_record'
  V4_INTEGRATION_AVAILABLE = true
  require_relative 'spec/integration/v4/support.rb'
  require_relative 'spec/integration/v4/support/rbac_helper.rb'
  puts 'RbacHelper loaded: ' + RbacHelper::ROLES.inspect
"
```

Expected: `RbacHelper loaded: {:db_manager=>"apt_test_db_manager", :app_user=>"apt_test_app_user"}`

- [ ] **Step 3: Commit**

```bash
git add spec/integration/v4/support/rbac_helper.rb
git commit -m "Add RbacHelper module for RBAC integration tests

Engine-aware role provisioning (PG CREATE ROLE, MySQL CREATE USER),
connect_as/restore for grant tests, setup_connects_to! for role-aware
routing tests. Auto-skip with actionable message when roles unavailable."
```

---

### Task 3: Role-Aware Connection Spec (PostgreSQL)

**Files:**
- Create: `spec/integration/v4/role_aware_connection_spec.rb`

**References:**
- `lib/apartment/patches/connection_handling.rb` — the code under test
- `spec/integration/v4/support.rb` — V4IntegrationHelper patterns
- `spec/integration/v4/support/rbac_helper.rb` — RbacHelper (Task 2)

- [ ] **Step 1: Write the spec file**

```ruby
# frozen_string_literal: true

require 'spec_helper'
require_relative 'support'
require_relative 'support/rbac_helper'

RSpec.describe 'Role-aware connection routing', :integration, :rbac, :postgresql_only,
               skip: (!V4_INTEGRATION_AVAILABLE || V4IntegrationHelper.database_engine != 'postgresql') && 'requires PostgreSQL' do
  include V4IntegrationHelper

  let(:tenant) { 'rbac_conn_tenant' }

  before do
    config = V4IntegrationHelper.establish_default_connection!
    RbacHelper.setup_connects_to!(config)

    Apartment.configure do |c|
      c.tenant_strategy = :schema
      c.tenants_provider = -> { [tenant] }
      c.default_tenant = 'public'
      c.check_pending_migrations = false
    end

    Apartment.adapter = V4IntegrationHelper.build_adapter(config)
    Apartment.activate!
    Apartment.adapter.create(tenant)
  end

  after do
    V4IntegrationHelper.cleanup_tenants!([tenant], Apartment.adapter)
    Apartment.clear_config
    Apartment::Current.reset
    RbacHelper.teardown_rbac_connections!
  end

  it 'creates separate pools per role for the same tenant' do
    writing_pool = nil
    writing_user = nil

    Apartment::Tenant.switch(tenant) do
      writing_pool = ActiveRecord::Base.connection_pool
      writing_user = ActiveRecord::Base.connection.execute('SELECT current_user AS cu').first['cu']
    end

    ActiveRecord::Base.connected_to(role: :db_manager) do
      Apartment::Tenant.switch(tenant) do
        mgr_pool = ActiveRecord::Base.connection_pool
        mgr_user = ActiveRecord::Base.connection.execute('SELECT current_user AS cu').first['cu']

        expect(mgr_pool).not_to eq(writing_pool)
        expect(mgr_user).to eq(RbacHelper::ROLES[:db_manager])
        expect(writing_user).not_to eq(mgr_user)
      end
    end
  end

  it 'uses distinct pool keys per role' do
    Apartment::Tenant.switch(tenant) { ActiveRecord::Base.connection }

    ActiveRecord::Base.connected_to(role: :db_manager) do
      Apartment::Tenant.switch(tenant) { ActiveRecord::Base.connection }
    end

    pool_keys = Apartment.pool_manager.stats[:tenants]
    expect(pool_keys).to include("#{tenant}:writing")
    expect(pool_keys).to include("#{tenant}:db_manager")
  end

  it 'propagates the db_manager username into tenant pool config' do
    ActiveRecord::Base.connected_to(role: :db_manager) do
      Apartment::Tenant.switch(tenant) do
        pool_config = ActiveRecord::Base.connection_pool.db_config.configuration_hash
        expect(pool_config[:username]).to eq(RbacHelper::ROLES[:db_manager])
      end
    end
  end
end
```

- [ ] **Step 2: Run the spec to verify it passes**

```bash
DATABASE_ENGINE=postgresql bundle exec appraisal rails-8.1-postgresql rspec spec/integration/v4/role_aware_connection_spec.rb --format documentation
```

Expected: 3 examples, 0 failures. If roles aren't provisioned locally, expect 3 examples skipped.

- [ ] **Step 3: Commit**

```bash
git add spec/integration/v4/role_aware_connection_spec.rb
git commit -m "Add role-aware connection integration tests

Verify ConnectionHandling creates separate pools per role for the
same tenant, with distinct pool keys and correct username propagation
from the active connected_to role's base config."
```

---

### Task 4: RBAC Grants Spec (PostgreSQL)

**Files:**
- Create: `spec/integration/v4/rbac_grants_spec.rb`

**References:**
- `lib/apartment/adapters/postgresql_schema_adapter.rb:37-60` — `grant_privileges` implementation
- `lib/apartment/adapters/abstract_adapter.rb` — `grant_tenant_privileges` dispatch

- [ ] **Step 1: Write the spec file**

```ruby
# frozen_string_literal: true

require 'spec_helper'
require_relative 'support'
require_relative 'support/rbac_helper'

RSpec.describe 'PostgreSQL RBAC privilege grants', :integration, :rbac, :postgresql_only,
               skip: (!V4_INTEGRATION_AVAILABLE || V4IntegrationHelper.database_engine != 'postgresql') && 'requires PostgreSQL' do
  include V4IntegrationHelper

  let(:tenant) { 'rbac_grants_tenant' }

  before do
    config = V4IntegrationHelper.establish_default_connection!

    # Create tenant as db_manager (owns the schema) with app_role grants
    RbacHelper.connect_as(:db_manager)

    Apartment.configure do |c|
      c.tenant_strategy = :schema
      c.tenants_provider = -> { [tenant] }
      c.default_tenant = 'public'
      c.app_role = RbacHelper::ROLES[:app_user]
      c.check_pending_migrations = false
    end

    Apartment.adapter = V4IntegrationHelper.build_adapter(
      config.merge('username' => RbacHelper::ROLES[:db_manager])
    )
    Apartment.activate!
    Apartment.adapter.create(tenant)

    # Create a test table as db_manager (inside the tenant schema)
    Apartment::Tenant.switch(tenant) do
      ActiveRecord::Base.connection.execute(<<~SQL)
        CREATE TABLE #{ActiveRecord::Base.connection.quote_table_name(tenant)}.widgets (
          id serial PRIMARY KEY,
          name varchar(255)
        )
      SQL
    end

    RbacHelper.restore_default_connection!
  end

  after do
    # Reconnect as default (superuser) to drop
    V4IntegrationHelper.establish_default_connection!
    Apartment.adapter = V4IntegrationHelper.build_adapter(
      V4IntegrationHelper.default_connection_config
    )
    V4IntegrationHelper.cleanup_tenants!([tenant], Apartment.adapter)
    Apartment.clear_config
    Apartment::Current.reset
    RbacHelper.teardown_rbac_connections!
  end

  context 'as app_user' do
    before { RbacHelper.connect_as(:app_user) }
    after  { RbacHelper.restore_default_connection! }

    it 'can SELECT, INSERT, UPDATE, DELETE' do
      conn = ActiveRecord::Base.connection
      conn.execute("INSERT INTO #{conn.quote_table_name(tenant)}.widgets (name) VALUES ('test')")

      result = conn.execute("SELECT name FROM #{conn.quote_table_name(tenant)}.widgets")
      expect(result.first['name']).to eq('test')

      conn.execute("UPDATE #{conn.quote_table_name(tenant)}.widgets SET name = 'updated'")

      result = conn.execute("SELECT name FROM #{conn.quote_table_name(tenant)}.widgets")
      expect(result.first['name']).to eq('updated')

      conn.execute("DELETE FROM #{conn.quote_table_name(tenant)}.widgets")
      result = conn.execute("SELECT count(*) AS c FROM #{conn.quote_table_name(tenant)}.widgets")
      expect(result.first['c'].to_i).to eq(0)
    end

    it 'cannot CREATE TABLE in the tenant schema' do
      expect {
        ActiveRecord::Base.connection.execute(
          "CREATE TABLE #{ActiveRecord::Base.connection.quote_table_name(tenant)}.forbidden (id serial)"
        )
      }.to raise_error(ActiveRecord::StatementInvalid, /permission denied/)
    end

    it 'cannot DROP SCHEMA' do
      expect {
        ActiveRecord::Base.connection.execute(
          "DROP SCHEMA #{ActiveRecord::Base.connection.quote_table_name(tenant)} CASCADE"
        )
      }.to raise_error(ActiveRecord::StatementInvalid, /must be owner|permission denied/)
    end
  end

  context 'ALTER DEFAULT PRIVILEGES' do
    it 'grants DML on tables created after initial tenant creation' do
      # As db_manager: create a new table after the tenant was created
      RbacHelper.connect_as(:db_manager)
      ActiveRecord::Base.connection.execute(<<~SQL)
        CREATE TABLE #{ActiveRecord::Base.connection.quote_table_name(tenant)}.gadgets (
          id serial PRIMARY KEY,
          label varchar(255)
        )
      SQL
      RbacHelper.restore_default_connection!

      # As app_user: verify DML works on the new table
      RbacHelper.connect_as(:app_user)
      conn = ActiveRecord::Base.connection
      conn.execute("INSERT INTO #{conn.quote_table_name(tenant)}.gadgets (label) VALUES ('shiny')")
      result = conn.execute("SELECT label FROM #{conn.quote_table_name(tenant)}.gadgets")
      expect(result.first['label']).to eq('shiny')
      RbacHelper.restore_default_connection!
    end
  end

  context 'as db_manager' do
    before { RbacHelper.connect_as(:db_manager) }
    after  { RbacHelper.restore_default_connection! }

    it 'can CREATE TABLE and DROP SCHEMA' do
      conn = ActiveRecord::Base.connection
      conn.execute(
        "CREATE TABLE #{conn.quote_table_name(tenant)}.temp_table (id serial PRIMARY KEY)"
      )
      conn.execute("DROP TABLE #{conn.quote_table_name(tenant)}.temp_table")
      # Verify full DDL: db_manager can drop the schema it owns
      conn.execute("DROP SCHEMA #{conn.quote_table_name(tenant)} CASCADE")
      # Recreate for cleanup consistency
      conn.execute("CREATE SCHEMA #{conn.quote_table_name(tenant)}")
    end
  end
end
```

- [ ] **Step 2: Run the spec**

```bash
DATABASE_ENGINE=postgresql bundle exec appraisal rails-8.1-postgresql rspec spec/integration/v4/rbac_grants_spec.rb --format documentation
```

Expected: 4 examples, 0 failures (or all skipped if roles not provisioned).

- [ ] **Step 3: Commit**

```bash
git add spec/integration/v4/rbac_grants_spec.rb
git commit -m "Add RBAC privilege grant integration tests (PostgreSQL)

Verify app_user can DML but not DDL in tenant schemas. Verify ALTER
DEFAULT PRIVILEGES fire for tables created after initial grants.
Verify db_manager retains full DDL privileges."
```

---

### Task 5: Migrator RBAC Spec (PostgreSQL)

**Files:**
- Create: `spec/integration/v4/migrator_rbac_spec.rb`

**References:**
- `lib/apartment/migrator.rb` — `with_migration_role`, `evict_migration_pools`
- `lib/apartment/patches/connection_handling.rb` — role-aware pool creation

- [ ] **Step 1: Write the spec file**

```ruby
# frozen_string_literal: true

require 'spec_helper'
require_relative 'support'
require_relative 'support/rbac_helper'
require 'apartment/migrator'

RSpec.describe 'Migrator with migration_role', :integration, :rbac, :postgresql_only,
               skip: (!V4_INTEGRATION_AVAILABLE || V4IntegrationHelper.database_engine != 'postgresql') && 'requires PostgreSQL' do
  include V4IntegrationHelper

  let(:tenants) { %w[rbac_mig_one rbac_mig_two] }
  let(:migration_dir) { Dir.mktmpdir('apartment_rbac_migrations') }

  before do
    config = V4IntegrationHelper.establish_default_connection!
    RbacHelper.setup_connects_to!(config)

    Apartment.configure do |c|
      c.tenant_strategy = :schema
      c.tenants_provider = -> { tenants }
      c.default_tenant = 'public'
      c.migration_role = :db_manager
      c.app_role = RbacHelper::ROLES[:app_user]
      c.check_pending_migrations = false
    end

    Apartment.adapter = V4IntegrationHelper.build_adapter(config)
    Apartment.activate!

    # Create tenants as db_manager (so db_manager owns the schemas)
    ActiveRecord::Base.connected_to(role: :db_manager) do
      tenants.each { |t| Apartment.adapter.create(t) }
    end

    # Write a real migration file
    timestamp = '20260401000001'
    File.write(File.join(migration_dir, "#{timestamp}_create_rbac_test_widgets.rb"), <<~RUBY)
      class CreateRbacTestWidgets < ActiveRecord::Migration[7.2]
        def change
          create_table :rbac_test_widgets do |t|
            t.string :name
          end
        end
      end
    RUBY

    # Point AR's migration context at our temp directory.
    # ActiveRecord::Migrator.migrations_paths is what connection_pool.migration_context reads.
    @original_migrations_paths = ActiveRecord::Migrator.migrations_paths
    ActiveRecord::Migrator.migrations_paths = [migration_dir]
  end

  after do
    # Restore migration paths
    ActiveRecord::Migrator.migrations_paths = @original_migrations_paths

    V4IntegrationHelper.establish_default_connection!
    Apartment.adapter = V4IntegrationHelper.build_adapter(
      V4IntegrationHelper.default_connection_config
    )
    V4IntegrationHelper.cleanup_tenants!(tenants, Apartment.adapter)
    Apartment.clear_config
    Apartment::Current.reset
    RbacHelper.teardown_rbac_connections!
    FileUtils.rm_rf(migration_dir)
  end

  it 'runs migrations as db_manager (table owned by db_manager)' do
    migrator = Apartment::Migrator.new(threads: 0)
    result = migrator.run

    expect(result).to be_success

    tenants.each do |t|
      Apartment::Tenant.switch(t) do
        owner = ActiveRecord::Base.connection.execute(<<~SQL).first['tableowner']
          SELECT tableowner FROM pg_tables
          WHERE schemaname = '#{t}' AND tablename = 'rbac_test_widgets'
        SQL
        expect(owner).to eq(RbacHelper::ROLES[:db_manager])
      end
    end
  end

  it 'app_user can DML on migrated tables via default privileges' do
    Apartment::Migrator.new(threads: 0).run

    RbacHelper.connect_as(:app_user)
    conn = ActiveRecord::Base.connection

    tenants.each do |t|
      conn.execute("INSERT INTO #{conn.quote_table_name(t)}.rbac_test_widgets (name) VALUES ('test')")
      result = conn.execute("SELECT name FROM #{conn.quote_table_name(t)}.rbac_test_widgets")
      expect(result.first['name']).to eq('test')
    end

    RbacHelper.restore_default_connection!
  end

  it 'evicts migration-role pools after run' do
    Apartment::Migrator.new(threads: 0).run

    db_mgr_keys = Apartment.pool_manager.stats[:tenants].select { |k| k.end_with?(':db_manager') }
    expect(db_mgr_keys).to be_empty
  end

  context 'with parallel threads' do
    it 'each thread uses db_manager credentials' do
      migrator = Apartment::Migrator.new(threads: 2)
      result = migrator.run

      expect(result).to be_success

      tenants.each do |t|
        Apartment::Tenant.switch(t) do
          owner = ActiveRecord::Base.connection.execute(<<~SQL).first['tableowner']
            SELECT tableowner FROM pg_tables
            WHERE schemaname = '#{t}' AND tablename = 'rbac_test_widgets'
          SQL
          expect(owner).to eq(RbacHelper::ROLES[:db_manager])
        end
      end
    end
  end
end
```

- [ ] **Step 2: Run the spec**

```bash
DATABASE_ENGINE=postgresql bundle exec appraisal rails-8.1-postgresql rspec spec/integration/v4/migrator_rbac_spec.rb --format documentation
```

Expected: 4 examples, 0 failures (or all skipped if roles not provisioned).

- [ ] **Step 3: Commit**

```bash
git add spec/integration/v4/migrator_rbac_spec.rb
git commit -m "Add Migrator RBAC integration tests (PostgreSQL)

Verify Migrator with migration_role: :db_manager uses elevated
credentials (table ownership check), app_user gets DML via default
privileges, migration-role pools evicted after run, and parallel
threads each use db_manager credentials."
```

---

### Task 6: MySQL RBAC Grants Spec

**Files:**
- Create: `spec/integration/v4/mysql_rbac_grants_spec.rb`

**References:**
- `lib/apartment/adapters/mysql2_adapter.rb:34-39` — `grant_privileges` implementation

- [ ] **Step 1: Write the spec file**

```ruby
# frozen_string_literal: true

require 'spec_helper'
require_relative 'support'
require_relative 'support/rbac_helper'

RSpec.describe 'MySQL RBAC privilege grants', :integration, :rbac, :mysql_only,
               skip: (!V4_INTEGRATION_AVAILABLE || V4IntegrationHelper.database_engine != 'mysql') && 'requires MySQL' do
  include V4IntegrationHelper

  let(:tenant) { 'rbac_grants_tenant' }

  before do
    config = V4IntegrationHelper.establish_default_connection!

    # Create tenant as db_manager with app_role grants
    RbacHelper.connect_as(:db_manager)

    Apartment.configure do |c|
      c.tenant_strategy = :database_name
      c.tenants_provider = -> { [tenant] }
      c.default_tenant = V4IntegrationHelper.default_tenant
      c.app_role = RbacHelper::ROLES[:app_user]
      c.check_pending_migrations = false
    end

    Apartment.adapter = V4IntegrationHelper.build_adapter(
      config.merge('username' => RbacHelper::ROLES[:db_manager])
    )
    Apartment.activate!
    Apartment.adapter.create(tenant)

    # Create a test table inside the tenant database
    Apartment::Tenant.switch(tenant) do
      ActiveRecord::Base.connection.execute(<<~SQL)
        CREATE TABLE widgets (
          id INT AUTO_INCREMENT PRIMARY KEY,
          name VARCHAR(255)
        )
      SQL
    end

    RbacHelper.restore_default_connection!
  end

  after do
    V4IntegrationHelper.establish_default_connection!
    Apartment.adapter = V4IntegrationHelper.build_adapter(
      V4IntegrationHelper.default_connection_config
    )
    V4IntegrationHelper.cleanup_tenants!([tenant], Apartment.adapter)
    Apartment.clear_config
    Apartment::Current.reset
    RbacHelper.teardown_rbac_connections!
  end

  context 'as app_user' do
    # Resolve the environmentified database name for SQL queries
    let(:db_name) { Apartment.adapter.environmentify(tenant) }

    before { RbacHelper.connect_as(:app_user) }
    after  { RbacHelper.restore_default_connection! }

    it 'can SELECT, INSERT, UPDATE, DELETE' do
      conn = ActiveRecord::Base.connection
      conn.execute("INSERT INTO `#{db_name}`.widgets (name) VALUES ('test')")

      result = conn.execute("SELECT name FROM `#{db_name}`.widgets")
      expect(result.first['name']).to eq('test')

      conn.execute("UPDATE `#{db_name}`.widgets SET name = 'updated'")
      conn.execute("DELETE FROM `#{db_name}`.widgets")
    end

    it 'cannot CREATE TABLE in the tenant database' do
      expect {
        ActiveRecord::Base.connection.execute(
          "CREATE TABLE `#{db_name}`.forbidden (id INT PRIMARY KEY)"
        )
      }.to raise_error(ActiveRecord::StatementInvalid, /command denied|Access denied/)
    end

    it 'cannot DROP DATABASE' do
      expect {
        ActiveRecord::Base.connection.execute("DROP DATABASE `#{db_name}`")
      }.to raise_error(ActiveRecord::StatementInvalid, /command denied|Access denied/)
    end
  end

  context 'as db_manager' do
    let(:db_name) { Apartment.adapter.environmentify(tenant) }

    before { RbacHelper.connect_as(:db_manager) }
    after  { RbacHelper.restore_default_connection! }

    it 'can CREATE TABLE and DROP it' do
      conn = ActiveRecord::Base.connection
      conn.execute("CREATE TABLE `#{db_name}`.temp_table (id INT PRIMARY KEY)")
      conn.execute("DROP TABLE `#{db_name}`.temp_table")
    end
  end
end
```

- [ ] **Step 2: Run the spec**

```bash
DATABASE_ENGINE=mysql bundle exec appraisal rails-8.1-mysql2 rspec spec/integration/v4/mysql_rbac_grants_spec.rb --format documentation
```

Expected: 4 examples, 0 failures (or all skipped if roles not provisioned).

- [ ] **Step 3: Commit**

```bash
git add spec/integration/v4/mysql_rbac_grants_spec.rb
git commit -m "Add RBAC privilege grant integration tests (MySQL)

Verify app_user can DML but not CREATE TABLE or DROP DATABASE.
Verify db_manager retains full DDL privileges."
```

---

### Task 7: Full Suite Verification

- [ ] **Step 1: Run all RBAC specs (PostgreSQL)**

```bash
DATABASE_ENGINE=postgresql bundle exec appraisal rails-8.1-postgresql rspec spec/integration/v4/ --tag rbac --format documentation
```

Expected: 11 PG examples pass (3 connection + 4 grants + 4 migrator).

- [ ] **Step 2: Run all RBAC specs (MySQL)**

```bash
DATABASE_ENGINE=mysql bundle exec appraisal rails-8.1-mysql2 rspec spec/integration/v4/ --tag rbac --format documentation
```

Expected: 4 MySQL examples pass.

- [ ] **Step 3: Run full integration suite to verify no regressions**

```bash
DATABASE_ENGINE=postgresql bundle exec appraisal rails-8.1-postgresql rspec spec/integration/v4/ --format progress
```

Expected: All existing specs still pass. RBAC specs either pass (roles provisioned) or skip (roles not provisioned).

- [ ] **Step 4: Run unit tests to verify no regressions**

```bash
bundle exec appraisal rails-8.1-sqlite3 rspec spec/unit/ --format progress
```

Expected: All unit tests pass.

- [ ] **Step 5: Run Rubocop on new files**

```bash
bundle exec rubocop spec/integration/v4/support/rbac_helper.rb spec/integration/v4/role_aware_connection_spec.rb spec/integration/v4/rbac_grants_spec.rb spec/integration/v4/migrator_rbac_spec.rb spec/integration/v4/mysql_rbac_grants_spec.rb
```

Expected: No offenses. Fix any that appear.

- [ ] **Step 6: Final commit (if any fixups needed)**

Only if Steps 1-5 revealed issues that needed fixes.

---

### Task 8: Update CLAUDE.md and Spec Documentation

**Files:**
- Modify: `spec/CLAUDE.md` — add RBAC integration test documentation
- Modify: `CLAUDE.md` — update test commands section

- [ ] **Step 1: Update spec/CLAUDE.md**

Add to the "Test Coverage" section under existing coverage areas:

```markdown
- ✅ RBAC integration (role-aware connections, privilege grants, Migrator with migration_role)
```

Add a brief section under "Integration Tests" describing the RBAC test files and how to run them.

- [ ] **Step 2: Update CLAUDE.md Commands section**

Add the RBAC test commands:

```bash
# RBAC integration tests (requires PostgreSQL with provisioned roles)
DATABASE_ENGINE=postgresql bundle exec appraisal rails-8.1-postgresql rspec spec/integration/v4/ --tag rbac

# MySQL RBAC tests
DATABASE_ENGINE=mysql bundle exec appraisal rails-8.1-mysql2 rspec spec/integration/v4/ --tag rbac
```

- [ ] **Step 3: Commit**

```bash
git add spec/CLAUDE.md CLAUDE.md
git commit -m "Update docs with RBAC integration test instructions"
```
