# v4 RBAC contract — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Apartment own role routing for tenant DDL and hand privilege policy to the adopter: rename `migration_role` to `ddl_role`, replace `app_role` with a two-phase `tenant_privilege_policy` callable, and demote the built-in grant SQL to a policy the adopter opts into.

**Architecture:** Three pieces. A `Apartment::Privileges::Context` value-ish object (plain frozen class, keyword init) carrying tenant, container name, connection, database role and phase. A `Apartment::Privileges.standard` factory returning a callable that asks the adapter for the statements belonging to the current phase and executes them. An adapter seam, `#standard_privilege_statements`, where per-engine SQL lives — PostgreSQL schema and MySQL implement it, the other two inherit a raise. `AbstractAdapter#create` invokes the configured policy once per phase inside the existing `ddl_role` wrap.

**Tech Stack:** Ruby >= 3.3, ActiveRecord 7.2–main, RSpec, Zeitwerk autoloading, Apartment v4 pool-per-tenant model.

**Spec:** `docs/designs/v4-rbac-contract.md` — read it before starting. The plan argues from it; where they disagree, the spec wins and the plan is wrong.

**Base branch:** `fix/v4-create-under-migration-role` (PR #490), which introduces `Apartment::MigrationRole.wrap`. That PR is green but awaiting review; branch from it, not from `main`. If #490 has merged by the time you start, branch from `main` and confirm `lib/apartment/migration_role.rb` exists before Task 1.

## Global Constraints

- **Public OSS gem.** Never reference CampusESP, `www`, or any private repo, path, class name, or PR in code, specs, comments, docs, commit messages, or PR bodies. The downstream consumer is "the primary adopter" or "an adopter".
- **Ruby floor `>= 3.3`.** Endless method definitions, `Data.define`, and `=>` rightward assignment are all available. Do not use anything newer.
- **No hard wrapping in markdown.** One line per paragraph in every `.md` file you touch.
- **`Data.define` is for value objects only.** `Privileges::Context` is deliberately NOT a `Data` — see the spec's context section. Do not "simplify" it into one.
- **`ConfigurationError`, never `NotImplementedError`, for unsupported strategies.** `NotImplementedError` descends from `ScriptError`, so `rescue StandardError` misses it. The gem's existing `NotImplementedError` raises for abstract adapter methods stay as they are.
- **No deprecation shim for `app_role`.** It is removed outright, including the callable form's `(tenant, connection)` signature.
- **Frozen string literals.** Every new file starts with `# frozen_string_literal: true`.
- **Rubocop clean before every commit**, on implementation and specs alike: `bundle exec rubocop <files>`.
- **Unit specs must not need a database.** `spec/unit/` runs with no DB; anything needing real roles goes in `spec/integration/v4/` tagged `:rbac`.

## Test commands

```bash
bundle exec rspec spec/unit/                                                   # unit, no DB
bundle exec rubocop lib spec                                                   # lint
DATABASE_ENGINE=postgresql bundle exec appraisal rails-8.1-postgresql rspec spec/integration/v4/ --tag rbac
DATABASE_ENGINE=postgresql bundle exec appraisal rails-8.1-postgresql rspec spec/integration/v4/
bundle exec appraisal rails-8.1-sqlite3 rspec spec/integration/v4/
```

---

### Task 1: Rename `migration_role` to `ddl_role`

Mechanical and wide. Do it first so every later task writes the new name.

**Files:** (this list was incomplete on first execution — the extra entries below were found by the sweep in Step 5, not by the plan)
- Modify: `lib/apartment/config.rb` (attr_accessor list line ~29, `initialize` line ~61, `validate!` lines ~236-238)
- Modify: `lib/apartment/migration_role.rb` (`wrap`)
- Modify: `lib/apartment/migrator.rb` (`evict_migration_pools`)
- Modify: `lib/apartment/adapters/abstract_adapter.rb` (`discard_migration_role_pool`, renamed in Step 4b)
- Modify: `lib/apartment/cli/migrations.rb`
- Modify: `lib/generators/apartment/install/templates/apartment.rb` (commented config line ~78)
- Modify: `README.md` (RBAC section), `CLAUDE.md`, `lib/apartment/CLAUDE.md`, `lib/apartment/adapters/CLAUDE.md`, `spec/CLAUDE.md`
- Test: `spec/unit/config_spec.rb`, `spec/unit/migrator_spec.rb`, `spec/unit/cli/migrations_spec.rb`, `spec/unit/generator/install_generator_spec.rb`, `spec/unit/adapters/abstract_adapter_spec.rb`, `spec/integration/v4/migrator_rbac_spec.rb`, `spec/integration/v4/support/rbac_helper.rb`

**Interfaces:**
- Consumes: nothing new.
- Produces: `Apartment.config.ddl_role` (Symbol or nil). `Apartment::MigrationRole.wrap(&)` reads `ddl_role`. `Apartment::Migrator.with_migration_role(&)` keeps its name (it is the documented entry point for CLI code) and still delegates to `MigrationRole.wrap`.

- [ ] **Step 1: Write the failing test**

Add to `spec/unit/config_spec.rb`, in the validation describe block:

```ruby
it 'accepts a Symbol ddl_role' do
  expect do
    Apartment.configure do |c|
      c.tenant_strategy = :schema
      c.tenants_provider = -> { [] }
      c.default_tenant = 'public'
      c.ddl_role = :db_manager
    end
  end.not_to(raise_error)

  expect(Apartment.config.ddl_role).to(eq(:db_manager))
end

it 'rejects a non-Symbol ddl_role' do
  expect do
    Apartment.configure do |c|
      c.tenant_strategy = :schema
      c.tenants_provider = -> { [] }
      c.default_tenant = 'public'
      c.ddl_role = 'db_manager'
    end
  end.to(raise_error(Apartment::ConfigurationError, /ddl_role must be nil or a Symbol/))
end
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `bundle exec rspec spec/unit/config_spec.rb -e ddl_role`
Expected: FAIL with `NoMethodError: undefined method 'ddl_role='`.

- [ ] **Step 3: Rename in config**

In `lib/apartment/config.rb`, replace `:migration_role` with `:ddl_role` in the `attr_accessor` list, `@migration_role = nil` with `@ddl_role = nil` in `initialize`, and the validation block with:

```ruby
      if @ddl_role && !@ddl_role.is_a?(Symbol)
        raise(ConfigurationError, "ddl_role must be nil or a Symbol, got: #{@ddl_role.inspect}")
      end
```

- [ ] **Step 4: Rename at every read site**

`lib/apartment/migration_role.rb`:

```ruby
    def wrap(&)
      role = Apartment.config.ddl_role
      role ? ActiveRecord::Base.connected_to(role: role, &) : yield
    end
```

`lib/apartment/migrator.rb` — `evict_migration_pools` reads the config directly:

```ruby
    def evict_migration_pools
      role = Apartment.config.ddl_role
      return unless role && Apartment.pool_manager
```

Leave `Migrator.with_migration_role` named as it is. It is the published entry point and renaming it is churn with no reader benefit; its delegation to `MigrationRole.wrap` already carries the widened meaning. The file `lib/apartment/migration_role.rb` and the module `Apartment::MigrationRole` keep their names for the same reason: they name the wrap, not the config key.

- [ ] **Step 4b: Rename the stale pool helper**

`AbstractAdapter#discard_migration_role_pool` becomes `#discard_ddl_role_pool`, and its doc comment's "migration-role pool" becomes "DDL-role pool". The pool key it builds now derives from `ddl_role`, so the old name is stale terminology. One spec example description in `spec/unit/adapters/abstract_adapter_spec.rb` names the same pool and should follow. No spec calls the private method by name, so the rename is safe.

Leave the "migration-role" prose in `lib/apartment/migrator.rb`, `spec/integration/v4/migrator_rbac_spec.rb` and `spec/integration/v4/create_migration_role_spec.rb` alone — those describe `evict_migration_pools` and the `MigrationRole` wrap, which keep their names.

- [ ] **Step 5: Update the remaining references**

```bash
grep -rn "migration_role" lib spec docs README.md CLAUDE.md **/CLAUDE.md
```

Include the `CLAUDE.md` files explicitly. A `lib spec docs README.md` sweep misses the root `CLAUDE.md`, `lib/apartment/CLAUDE.md`, `lib/apartment/adapters/CLAUDE.md` and `spec/CLAUDE.md`, all of which name the config key. Rename the key in them here; Task 9 rewrites those entries substantively.

Update every hit except the `with_migration_role` method name itself and prose in `docs/designs/` that describes historical decisions. In `lib/generators/apartment/install/templates/apartment.rb`, the commented line becomes:

```ruby
  # config.ddl_role                = nil   # e.g. :db_manager - the role all tenant DDL runs on
```

Align the `=` with its neighbours in that file, and keep the comment ASCII — the surrounding comments use a hyphen, not an em dash.

- [ ] **Step 6: Run the tests**

Run: `bundle exec rspec spec/unit/ && bundle exec rubocop lib spec`
Expected: `1140 examples, 0 failures` (1138 on this base plus the two new config examples), and no offenses. `spec/unit/migrator_spec.rb` has `c.migration_role = :db_manager` in several examples; they must be updated in Step 5 or they fail here.

- [ ] **Step 7: Run the RBAC integration lane**

Run: `DATABASE_ENGINE=postgresql bundle exec appraisal rails-8.1-postgresql rspec spec/integration/v4/ --tag rbac`
Expected: PASS. If every example skips, role provisioning failed — see `docs/designs/v4-phase5.2-rbac-integration-tests.md`. A skipped lane is not a passing lane.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "Refactor(v4): rename migration_role to ddl_role

The wrap covers container creation and schema import, not only migrations,
so the name was already wrong. Pre-GA under a soft-deprecation posture, so
renamed rather than aliased.

Migrator.with_migration_role keeps its name: it is the published entry point
and it already delegates to MigrationRole.wrap."
```

---

### Task 2: `Privileges::Context`

**Files:**
- Create: `lib/apartment/privileges/context.rb`
- Test: `spec/unit/privileges/context_spec.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: `Apartment::Privileges::Context.new(tenant:, container_name:, connection:, db_role:, phase:)` with readers `#tenant`, `#container_name`, `#connection`, `#db_role`, `#phase`, and `#quoted_container`, `#before_schema_load?`, `#after_schema_load?`. Instances are frozen. Later tasks construct it; adopter policies only read it.

- [ ] **Step 1: Write the failing test**

Create `spec/unit/privileges/context_spec.rb`:

```ruby
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe(Apartment::Privileges::Context) do
  let(:connection) { instance_double(ActiveRecord::ConnectionAdapters::AbstractAdapter) }

  def build(phase: :before_schema_load)
    described_class.new(
      tenant: 'acme', container_name: 'acme_test', connection: connection,
      db_role: 'db_manager', phase: phase
    )
  end

  it 'exposes every field it was built with', :aggregate_failures do
    ctx = build

    expect(ctx.tenant).to(eq('acme'))
    expect(ctx.container_name).to(eq('acme_test'))
    expect(ctx.connection).to(be(connection))
    expect(ctx.db_role).to(eq('db_manager'))
    expect(ctx.phase).to(eq(:before_schema_load))
  end

  it 'answers the phase predicates', :aggregate_failures do
    expect(build(phase: :before_schema_load)).to(be_before_schema_load)
    expect(build(phase: :before_schema_load)).not_to(be_after_schema_load)
    expect(build(phase: :after_schema_load)).to(be_after_schema_load)
  end

  it 'quotes the container name through the connection' do
    allow(connection).to(receive(:quote_table_name).with('acme_test').and_return('"acme_test"'))

    expect(build.quoted_container).to(eq('"acme_test"'))
  end

  it 'is frozen, so a policy cannot mutate what a later phase sees' do
    expect(build).to(be_frozen)
  end

  # The compatibility promise in docs/designs/v4-rbac-contract.md: a policy that
  # reads attributes keeps working when a field is added. Data.define would have
  # broken this for anyone constructing or positionally destructuring a context.
  it 'accepts an unknown future field without breaking existing readers' do
    ctx = described_class.new(
      tenant: 'acme', container_name: 'acme_test', connection: connection,
      db_role: 'db_manager', phase: :before_schema_load, future_field: 'ignored'
    )

    expect(ctx.tenant).to(eq('acme'))
  end
end
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `bundle exec rspec spec/unit/privileges/context_spec.rb`
Expected: FAIL with `NameError: uninitialized constant Apartment::Privileges`.

- [ ] **Step 3: Write the minimal implementation**

Create `lib/apartment/privileges/context.rb`:

```ruby
# frozen_string_literal: true

module Apartment
  module Privileges
    # What a tenant_privilege_policy receives. One instance per phase.
    #
    # Deliberately not Data.define, though Data is house style for value objects
    # (Migrator::Result, PoolObserver::Sample). This is not a value object: it
    # carries a live connection, which is mutable and meaningless outside the
    # invocation, and Data would give it value equality, hashing and positional
    # decomposition as public semantics. Data also cannot deliver the additive-only
    # promise below — appending a member adds a required positional argument and a
    # required keyword to .new, and Data responds to #deconstruct, so an adopter
    # constructing a context in a unit test or destructuring it positionally would
    # break on a minor release.
    #
    # Additive-only: new fields arrive as keyword arguments with defaults, and
    # unknown keywords are ignored, so a policy reading attributes off a context
    # Apartment handed it keeps working. Construction is the gem's business.
    class Context
      attr_reader :tenant, :container_name, :connection, :db_role, :phase

      # @param tenant [String] the tenant name as Apartment knows it
      # @param container_name [String] the physical schema or database to address
      # @param connection [ActiveRecord::ConnectionAdapters::AbstractAdapter]
      #   valid for this invocation only; do not retain it
      # @param db_role [String, nil] the executing database role, nil where the
      #   engine has no role system
      # @param phase [Symbol] :before_schema_load or :after_schema_load
      def initialize(tenant:, container_name:, connection:, db_role:, phase:, **)
        @tenant = tenant
        @container_name = container_name
        @connection = connection
        @db_role = db_role
        @phase = phase
        freeze
      end

      def before_schema_load? = phase == :before_schema_load
      def after_schema_load? = phase == :after_schema_load

      # The value every policy needs. Provided so that copied example code quotes
      # by default rather than interpolating a raw identifier.
      def quoted_container = connection.quote_table_name(container_name)
    end
  end
end
```

- [ ] **Step 4: Exclude the file from `Metrics/ParameterLists`**

Five keyword parameters plus the anonymous `**` counts as 6 against a max of 5 — the cop counts keyword arguments. The signature is the design, so exclude the file rather than change it. `.rubocop.yml` already excludes `lib/apartment/pool_reaper.rb` from this cop; add a second entry in the same shape, with a comment saying why:

```yaml
Metrics/ParameterLists:
  Exclude:
    - lib/apartment/pool_reaper.rb
    # Five keyword fields plus the anonymous ** that keeps Context additive-only.
    - lib/apartment/privileges/context.rb
```

Do **not** set `CountKeywordArgs: false` repo-wide. That is a lint-policy change affecting every file, and it is out of scope for this task.

- [ ] **Step 5: Run the tests**

Run: `bundle exec rspec spec/unit/privileges/context_spec.rb spec/unit/zeitwerk_eager_load_spec.rb && bundle exec rubocop lib spec`
Expected: PASS, no offenses. Zeitwerk resolves `Apartment::Privileges::Context` from the directory as an implicit namespace with no `privileges.rb` present; Task 4 converting it to an explicit namespace is accepted, so the task order here is correct.

- [ ] **Step 6: Commit**

```bash
git add lib/apartment/privileges/context.rb spec/unit/privileges/context_spec.rb .rubocop.yml
git commit -m "Feat(v4): add Privileges::Context

What a tenant_privilege_policy receives, one instance per phase. A plain frozen
class rather than Data.define: it carries a live connection, so value equality
and positional decomposition are wrong semantics for it, and Data cannot deliver
the additive-only compatibility promise the design makes."
```

---

### Task 3: The adapter statement seam

The SQL moves out of the create path and into a per-engine, side-effect-free builder. Statements are a pure function of their inputs, so they unit-test without a database.

**Files:**
- Modify: `lib/apartment/adapters/abstract_adapter.rb` (add `#standard_privilege_statements`, `#current_db_role`)
- Modify: `lib/apartment/adapters/postgresql_schema_adapter.rb` (implement both; delete `#grant_privileges`)
- Modify: `lib/apartment/adapters/mysql2_adapter.rb` (implement both; delete `#grant_privileges`)
- Test: `spec/unit/adapters/postgresql_schema_adapter_spec.rb`, `spec/unit/adapters/mysql2_adapter_spec.rb`, `spec/unit/adapters/abstract_adapter_spec.rb`

**Interfaces:**
- Consumes: `Apartment::Privileges::Context` from Task 2.
- Produces:
  - `AbstractAdapter#standard_privilege_statements(ctx, grant_to:, include_functions:)` → `Array<String>`. Base raises `Apartment::ConfigurationError`. Called once per phase; returns the statements for `ctx.phase` only, and `[]` for a phase that engine does not need.
  - `AbstractAdapter#current_db_role(connection)` → `String` or `nil`. Base returns `nil`.

- [ ] **Step 1: Write the failing test for PostgreSQL**

Add to `spec/unit/adapters/postgresql_schema_adapter_spec.rb`:

```ruby
  describe '#standard_privilege_statements' do
    let(:connection) { double('Connection') }

    def context(phase)
      Apartment::Privileges::Context.new(
        tenant: 'acme', container_name: 'acme', connection: connection,
        db_role: 'db_manager', phase: phase
      )
    end

    before do
      allow(connection).to(receive(:quote_table_name)) { |name| %("#{name}") }
      reconfigure
    end

    # The default-privileges rules go BEFORE the import so they cover imported
    # tables and everything migrations add later. Getting this backwards is the
    # regression the two-phase design exists to prevent — see the spec.
    it 'issues the default-privileges rules before the schema load', :aggregate_failures do
      statements = adapter.standard_privilege_statements(
        context(:before_schema_load), grant_to: 'app_user', include_functions: true
      )

      expect(statements).to(include(a_string_matching(/GRANT USAGE ON SCHEMA "acme" TO "app_user"/)))
      expect(statements.grep(/ALTER DEFAULT PRIVILEGES/).size).to(eq(3))
      expect(statements).to(include(a_string_matching(/ALTER DEFAULT PRIVILEGES FOR ROLE "db_manager"/)))
      expect(statements).to(include(a_string_matching(/ON FUNCTIONS TO "app_user"/)))
    end

    it 'omits the functions rule when include_functions is false' do
      statements = adapter.standard_privilege_statements(
        context(:before_schema_load), grant_to: 'app_user', include_functions: false
      )

      expect(statements.grep(/ON FUNCTIONS/)).to(be_empty)
    end

    # Objects that exist by now: the import created them, and the default-privileges
    # rule does not retroactively cover objects created before it was recorded.
    it 'grants on existing objects after the schema load', :aggregate_failures do
      statements = adapter.standard_privilege_statements(
        context(:after_schema_load), grant_to: 'app_user', include_functions: true
      )

      expect(statements).to(include(a_string_matching(/ON ALL TABLES IN SCHEMA "acme"/)))
      expect(statements).to(include(a_string_matching(/ON ALL SEQUENCES IN SCHEMA "acme"/)))
      expect(statements.grep(/ALTER DEFAULT PRIVILEGES/)).to(be_empty)
    end

    it 'grants to every role it is given' do
      statements = adapter.standard_privilege_statements(
        context(:after_schema_load), grant_to: %w[app_web app_worker], include_functions: true
      )

      expect(statements.first).to(match(/TO "app_web", "app_worker"/))
    end
  end
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `bundle exec rspec spec/unit/adapters/postgresql_schema_adapter_spec.rb -e standard_privilege_statements`
Expected: FAIL with `NoMethodError: undefined method 'standard_privilege_statements'`.

**Method visibility matters here and the snippets below do not carry it.** Each adapter file has `protected` and then `private` sections, and `grant_privileges` sat under `private`. Pasting the replacements where it was makes them private, and the first green run fails with "protected method 'standard_privilege_statements' called". Put both public methods immediately BEFORE the `protected` keyword in each adapter, and any helper in the existing `private` section. Do not paste the `private` keyword that appears inside the PostgreSQL snippet below — the file already has one.

- [ ] **Step 3: Add the base seam**

In `lib/apartment/adapters/abstract_adapter.rb`, public section:

```ruby
      # The statements Privileges.standard should execute for ctx.phase, or [] when
      # this engine needs none in that phase. A pure function of its inputs: build,
      # do not execute, so the SQL is unit-testable without a database.
      #
      # ConfigurationError rather than NotImplementedError. An adopter who configured
      # the standard policy on a strategy that has none made a configuration mistake,
      # and NotImplementedError descends from ScriptError, so `rescue StandardError`
      # around Tenant.create would not catch it. The NotImplementedError raises
      # elsewhere in this class mean something different: a subclass owes an
      # implementation.
      def standard_privilege_statements(_ctx, grant_to:, include_functions: true) # rubocop:disable Lint/UnusedMethodArgument
        raise(Apartment::ConfigurationError,
              "Apartment::Privileges.standard does not support #{self.class.name}. " \
              'Write a tenant_privilege_policy for this strategy; see docs/rbac.md.')
      end

      # The executing database role, for policies that need to name it explicitly
      # (PostgreSQL's ALTER DEFAULT PRIVILEGES FOR ROLE). nil where the engine has
      # no role system. Token shape differs by engine, so each adapter answers.
      def current_db_role(_connection)
        nil
      end
```

- [ ] **Step 4: Implement PostgreSQL**

In `lib/apartment/adapters/postgresql_schema_adapter.rb`, replace `#grant_privileges` (currently private, around lines 92-115) with these public methods:

```ruby
      def standard_privilege_statements(ctx, grant_to:, include_functions: true)
        roles = Array(grant_to).map { |role| ctx.connection.quote_table_name(role) }.join(', ')
        schema = ctx.quoted_container

        if ctx.before_schema_load?
          before_schema_load_statements(ctx, schema, roles, include_functions)
        else
          [
            "GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA #{schema} TO #{roles}",
            "GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA #{schema} TO #{roles}",
          ]
        end
      end

      # pg_get_userbyid-free: current_user is what ALTER DEFAULT PRIVILEGES scopes to
      # when FOR ROLE is omitted, so it is the role a policy must name to be explicit.
      def current_db_role(connection)
        connection.select_value('SELECT current_user')
      end

      private

      # FOR ROLE is explicit rather than implied by the executing role. Omitting it
      # is what let a rule be recorded under one role while tables were created
      # under another — see docs/designs/v4-rbac-contract.md.
      def before_schema_load_statements(ctx, schema, roles, include_functions)
        grantor = ctx.connection.quote_table_name(ctx.db_role)
        defaults = "ALTER DEFAULT PRIVILEGES FOR ROLE #{grantor} IN SCHEMA #{schema} GRANT"

        statements = [
          "GRANT USAGE ON SCHEMA #{schema} TO #{roles}",
          "#{defaults} SELECT, INSERT, UPDATE, DELETE ON TABLES TO #{roles}",
          "#{defaults} USAGE, SELECT ON SEQUENCES TO #{roles}",
        ]
        statements << "#{defaults} EXECUTE ON FUNCTIONS TO #{roles}" if include_functions
        statements
      end
```

- [ ] **Step 5: Run the PostgreSQL tests**

Run: `bundle exec rspec spec/unit/adapters/postgresql_schema_adapter_spec.rb`
Expected: PASS. Existing examples for the deleted `#grant_privileges` will fail; delete them, their behaviour is now covered above.

- [ ] **Step 6: Write the failing test for MySQL**

Add to `spec/unit/adapters/mysql2_adapter_spec.rb`:

```ruby
  describe '#standard_privilege_statements' do
    let(:connection) { double('Connection') }

    def context(phase)
      Apartment::Privileges::Context.new(
        tenant: 'acme', container_name: 'acme_test', connection: connection,
        db_role: 'db_manager@%', phase: phase
      )
    end

    before do
      allow(connection).to(receive(:quote_table_name)) { |name| "`#{name}`" }
      allow(connection).to(receive(:quote)) { |value| "'#{value}'" }
      reconfigure
    end

    # MySQL's database-scoped grant is pattern-based: it already covers tables the
    # import and later migrations create, so there is nothing to do afterwards.
    # This asymmetry with PostgreSQL is why statements live behind an adapter seam.
    it 'grants once, before the schema load', :aggregate_failures do
      statements = adapter.standard_privilege_statements(
        context(:before_schema_load), grant_to: 'app_user', include_functions: true
      )

      expect(statements.size).to(eq(1))
      expect(statements.first).to(match(/GRANT SELECT, INSERT, UPDATE, DELETE ON `acme_test`\.\* TO 'app_user'@'%'/))
    end

    it 'needs no statements after the schema load' do
      statements = adapter.standard_privilege_statements(
        context(:after_schema_load), grant_to: 'app_user', include_functions: true
      )

      expect(statements).to(be_empty)
    end

    it 'grants to every account it is given' do
      statements = adapter.standard_privilege_statements(
        context(:before_schema_load), grant_to: %w[app_web app_worker], include_functions: true
      )

      expect(statements.first).to(match(/TO 'app_web'@'%', 'app_worker'@'%'/))
    end
  end
```

- [ ] **Step 7: Run it to make sure it fails**

Run: `bundle exec rspec spec/unit/adapters/mysql2_adapter_spec.rb -e standard_privilege_statements`
Expected: FAIL — the base implementation raises `Apartment::ConfigurationError`. Expect **six** failures from the three examples: that file is a `shared_examples` block run for both `Mysql2Adapter` and `TrilogyAdapter`, so every count in it doubles.

- [ ] **Step 8: Implement MySQL**

In `lib/apartment/adapters/mysql2_adapter.rb`, replace the private `#grant_privileges` with:

```ruby
      # MySQL has no ALTER DEFAULT PRIVILEGES. `ON db.*` is pattern-based and covers
      # objects created later, so one statement in the first phase is the whole
      # policy and include_functions has nothing to control here.
      def standard_privilege_statements(ctx, grant_to:, include_functions: true) # rubocop:disable Lint/UnusedMethodArgument
        return [] unless ctx.before_schema_load?

        accounts = Array(grant_to).map { |role| "#{ctx.connection.quote(role)}@'%'" }.join(', ')
        ["GRANT SELECT, INSERT, UPDATE, DELETE ON #{ctx.quoted_container}.* TO #{accounts}"]
      end

      # Returns MySQL's `role@host` form. Its GRANT syntax wants the halves quoted
      # separately, which is why the statement builder above splits rather than
      # interpolating this value whole.
      def current_db_role(connection)
        connection.select_value('SELECT CURRENT_USER()')
      end
```

- [ ] **Step 9: Add the base-raise test**

Add to `spec/unit/adapters/abstract_adapter_spec.rb`:

```ruby
  describe '#standard_privilege_statements' do
    let(:connection) { double('Connection') }

    # ConfigurationError, not NotImplementedError: the latter descends from
    # ScriptError, so an adopter's `rescue StandardError` around Tenant.create
    # would miss it and the process would die on a misconfiguration.
    it 'raises a rescuable error on a strategy with no standard policy', :aggregate_failures do
      reconfigure
      ctx = Apartment::Privileges::Context.new(
        tenant: 'acme', container_name: 'acme', connection: connection,
        db_role: nil, phase: :before_schema_load
      )

      raised = nil
      begin
        adapter.standard_privilege_statements(ctx, grant_to: 'app_user')
      rescue StandardError => e
        raised = e
      end

      expect(raised).to(be_a(Apartment::ConfigurationError))
      expect(raised.message).to(match(/does not support/))
    end

    it 'reports no database role by default' do
      reconfigure
      expect(adapter.current_db_role(connection)).to(be_nil)
    end
  end
```

- [ ] **Step 10: Run everything**

Run: `bundle exec rspec spec/unit/ && bundle exec rubocop lib spec`
Expected: PASS, no offenses. `AbstractAdapter#grant_tenant_privileges` still exists and still calls `grant_privileges`, which the two adapters no longer define — Task 5 removes both. Until then the old `#grant_tenant_privileges` examples in `abstract_adapter_spec.rb` will fail. Delete those examples now; Task 5's specs replace them.

- [ ] **Step 11: Commit**

```bash
git add -A
git commit -m "Feat(v4): move privilege SQL behind an adapter statement seam

standard_privilege_statements builds the statements for one phase and returns
them; it does not execute. Pure inputs to output, so the SQL unit-tests without
a database, and per-engine asymmetry lives with the engine: PostgreSQL needs
both phases (default privileges before the import, grants on existing objects
after), MySQL needs only the first because ON db.* already covers future tables.

FOR ROLE is now explicit. Omitting it is what allowed a default-privileges rule
to be recorded under one role while tables were created under another.

Unsupported strategies raise ConfigurationError, not NotImplementedError, which
descends from ScriptError and escapes rescue StandardError."
```

---

### Task 4: `Privileges.standard`

**Files:**
- Create: `lib/apartment/privileges.rb`
- Test: `spec/unit/privileges_spec.rb`

**Interfaces:**
- Consumes: `Privileges::Context` (Task 2); `Apartment.adapter#standard_privilege_statements` (Task 3).
- Produces: `Apartment::Privileges.standard(grant_to:, include_functions: true)` → a callable taking one `Context`, returning the statements it executed. Suitable as `config.tenant_privilege_policy`.

- [ ] **Step 1: Write the failing test**

Create `spec/unit/privileges_spec.rb`:

```ruby
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe(Apartment::Privileges) do
  describe '.standard' do
    let(:connection) { double('Connection') }
    let(:adapter) { double('Adapter') }

    def context(phase = :before_schema_load)
      described_class::Context.new(
        tenant: 'acme', container_name: 'acme', connection: connection,
        db_role: 'db_manager', phase: phase
      )
    end

    before { allow(Apartment).to(receive(:adapter).and_return(adapter)) }

    it 'returns a callable, so it can be assigned straight to the config key' do
      expect(described_class.standard(grant_to: 'app_user')).to(respond_to(:call))
    end

    it 'executes the statements the adapter supplies for that phase', :aggregate_failures do
      # ['app_user'], not 'app_user': the factory normalizes with Array() once, so the
      # adapter seam always receives one shape. The adapters' own Array() call is
      # tolerance, not the contract.
      allow(adapter).to(receive(:standard_privilege_statements)
        .with(anything, grant_to: ['app_user'], include_functions: true)
        .and_return(['GRANT A', 'GRANT B']))
      allow(connection).to(receive(:execute))

      described_class.standard(grant_to: 'app_user').call(context)

      expect(connection).to(have_received(:execute).with('GRANT A').ordered)
      expect(connection).to(have_received(:execute).with('GRANT B').ordered)
    end

    it 'accepts an Array of roles and forwards it as given' do
      expect(adapter).to(receive(:standard_privilege_statements)
        .with(anything, grant_to: %w[app_web app_worker], include_functions: true)
        .and_return([]))

      described_class.standard(grant_to: %w[app_web app_worker]).call(context)
    end

    it 'passes include_functions through' do
      expect(adapter).to(receive(:standard_privilege_statements)
        .with(anything, grant_to: ['app_user'], include_functions: false)
        .and_return([]))

      described_class.standard(grant_to: 'app_user', include_functions: false).call(context)
    end

    # The phase mapping is the adapter's; the policy must not second-guess it.
    it 'executes nothing when the adapter needs no statements in this phase' do
      allow(adapter).to(receive(:standard_privilege_statements).and_return([]))
      expect(connection).not_to(receive(:execute))

      described_class.standard(grant_to: 'app_user').call(context(:after_schema_load))
    end

    it 'rejects an empty grant_to at build time, not at create time' do
      expect { described_class.standard(grant_to: []) }
        .to(raise_error(Apartment::ConfigurationError, /grant_to/))
    end

    it 'rejects a non-String grant_to' do
      expect { described_class.standard(grant_to: [:app_user]) }
        .to(raise_error(Apartment::ConfigurationError, /grant_to/))
    end
  end
end
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `bundle exec rspec spec/unit/privileges_spec.rb`
Expected: FAIL with `NoMethodError: undefined method 'standard' for Apartment::Privileges`.

- [ ] **Step 3: Write the minimal implementation**

Create `lib/apartment/privileges.rb`:

```ruby
# frozen_string_literal: true

module Apartment
  # Prebuilt tenant privilege policies. Apartment issues no grants of its own; a
  # policy runs only because an adopter configured one.
  module Privileges
    module_function

    # A policy granting an app role the privileges a routed tenant normally needs.
    #
    # Returns a callable rather than executing, so it can be assigned directly to
    # config.tenant_privilege_policy and so it owns its own phase mapping. As an
    # immediate call it would have forced every adopter to re-derive which
    # statements belong before the schema import and which after; that mapping is
    # exactly the knowledge this helper exists to carry.
    #
    #   c.tenant_privilege_policy = Apartment::Privileges.standard(grant_to: 'app_user')
    #
    # Composable, because it is just a callable:
    #
    #   standard = Apartment::Privileges.standard(grant_to: 'app_user')
    #   c.tenant_privilege_policy = lambda { |ctx|
    #     standard.call(ctx)
    #     ctx.connection.execute('...') if ctx.after_schema_load?
    #   }
    #
    # @param grant_to [String, Array<String>] role names, or MySQL accounts
    # @param include_functions [Boolean] PostgreSQL only; the EXECUTE ON FUNCTIONS
    #   default-privileges rule. MySQL has no equivalent and ignores it.
    # @return [Proc] takes one Privileges::Context, returns the statements executed
    def standard(grant_to:, include_functions: true)
      roles = Array(grant_to)
      if roles.empty? || !roles.all?(String)
        raise(Apartment::ConfigurationError,
              "grant_to must be a String or a non-empty Array of Strings, got: #{grant_to.inspect}")
      end

      lambda do |ctx|
        statements = Apartment.adapter.standard_privilege_statements(
          ctx, grant_to: roles, include_functions: include_functions
        )
        statements.each { |sql| ctx.connection.execute(sql) }
      end
    end
  end
end
```

- [ ] **Step 4: Run the tests**

Run: `bundle exec rspec spec/unit/privileges_spec.rb && bundle exec rubocop lib/apartment/privileges.rb spec/unit/privileges_spec.rb`
Expected: PASS, no offenses. If `.standard(grant_to: 'app_user')` fails the String check, `Array('app_user')` is `['app_user']` — confirm you did not write `grant_to.all?`.

- [ ] **Step 5: Commit**

```bash
git add lib/apartment/privileges.rb spec/unit/privileges_spec.rb
git commit -m "Feat(v4): add Privileges.standard policy factory

Returns a callable that owns its own phase mapping, so an adopter assigns it to
tenant_privilege_policy without knowing which statements belong before the schema
import and which after. grant_to is validated when the policy is built rather
than when a tenant is created."
```

---

### Task 5: Replace `app_role` with `tenant_privilege_policy` and invoke it

The behavioural centre of the plan.

**Files:**
- Modify: `lib/apartment/config.rb` (attr list, `initialize`, `freeze!` line ~126, `validate!` lines ~240-242)
- Modify: `lib/apartment/adapters/abstract_adapter.rb` (`#create`, `#run_tenant_ddl`; delete `#grant_tenant_privileges`)
- Test: `spec/unit/config_spec.rb`, `spec/unit/adapters/abstract_adapter_spec.rb`

**Interfaces:**
- Consumes: `Privileges::Context` (Task 2), `#current_db_role` (Task 3), `Privileges.standard` (Task 4), `MigrationRole.wrap` (base branch).
- Produces: `Apartment.config.tenant_privilege_policy` (callable or nil). `AbstractAdapter#create` invokes it once per phase inside the `ddl_role` wrap. `app_role` and `grant_tenant_privileges` no longer exist.

- [ ] **Step 1: Write the failing config test**

Add to `spec/unit/config_spec.rb`:

```ruby
it 'accepts a callable tenant_privilege_policy' do
  policy = ->(_ctx) { nil }
  Apartment.configure do |c|
    c.tenant_strategy = :schema
    c.tenants_provider = -> { [] }
    c.default_tenant = 'public'
    c.tenant_privilege_policy = policy
  end

  expect(Apartment.config.tenant_privilege_policy).to(be(policy))
end

it 'rejects a non-callable tenant_privilege_policy' do
  expect do
    Apartment.configure do |c|
      c.tenant_strategy = :schema
      c.tenants_provider = -> { [] }
      c.default_tenant = 'public'
      c.tenant_privilege_policy = 'app_user'
    end
  end.to(raise_error(Apartment::ConfigurationError, /tenant_privilege_policy must be nil or a callable/))
end

it 'no longer accepts app_role' do
  expect do
    Apartment.configure { |c| c.app_role = 'app_user' }
  end.to(raise_error(NoMethodError))
end
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `bundle exec rspec spec/unit/config_spec.rb -e tenant_privilege_policy -e app_role`
Expected: FAIL with `NoMethodError: undefined method 'tenant_privilege_policy='`.

- [ ] **Step 3: Swap the config key**

In `lib/apartment/config.rb`: replace `:app_role` with `:tenant_privilege_policy` in `attr_accessor`; replace `@app_role = nil` with `@tenant_privilege_policy = nil`; delete the `@app_role.freeze if @app_role.is_a?(String)` line in `freeze!` (a callable must not be frozen — freezing a lambda is harmless but pointless, and there is no String form left); replace the validation with:

```ruby
      if @tenant_privilege_policy && !@tenant_privilege_policy.respond_to?(:call)
        raise(ConfigurationError,
              'tenant_privilege_policy must be nil or a callable, ' \
              "got: #{@tenant_privilege_policy.inspect}")
      end
```

- [ ] **Step 4: Write the failing invocation test**

Add to `spec/unit/adapters/abstract_adapter_spec.rb`, inside the existing `#create under a configured migration_role` describe (renamed by Task 1 to `ddl_role`):

```ruby
  describe '#create and the privilege policy' do
    let(:connection) { double('Connection') }

    before do
      allow(Apartment::Instrumentation).to(receive(:instrument))
      allow(ActiveRecord::Base).to(receive(:connection).and_return(connection))
      allow(adapter).to(receive(:current_db_role).and_return('db_manager'))
    end

    it 'invokes the policy once per phase, in order' do
      phases = []
      reconfigure(tenant_privilege_policy: ->(ctx) { phases << ctx.phase })

      adapter.create('acme')

      expect(phases).to(eq(%i[before_schema_load after_schema_load]))
    end

    it 'invokes both phases even when no schema is loaded' do
      phases = []
      reconfigure(schema_load_strategy: nil, tenant_privilege_policy: ->(ctx) { phases << ctx.phase })

      adapter.create('acme')

      # :after_schema_load means "after the import step", including when that step
      # did nothing. A policy behaves the same either way.
      expect(phases.size).to(eq(2))
    end

    it 'brackets the schema import between the phases' do
      order = []
      allow(adapter).to(receive(:import_schema) { order << :import })
      reconfigure(schema_load_strategy: :schema_rb,
                  tenant_privilege_policy: ->(ctx) { order << ctx.phase })

      adapter.create('acme')

      expect(order).to(eq(%i[before_schema_load import after_schema_load]))
    end

    it 'gives the policy the physical container name, not the logical tenant' do
      names = []
      reconfigure(environmentify_strategy: :append,
                  tenant_privilege_policy: ->(ctx) { names << [ctx.tenant, ctx.container_name] })

      adapter.create('acme')

      # A policy interpolating the logical name would target the wrong object
      # under any environmentify_strategy.
      expect(names.first).to(eq(['acme', adapter.send(:physical_tenant_name, 'acme')]))
    end

    it 'resolves the database role once, not once per phase' do
      reconfigure(tenant_privilege_policy: ->(_ctx) { nil })

      adapter.create('acme')

      expect(adapter).to(have_received(:current_db_role).once)
    end

    it 'aborts the create when the policy raises, without seeding', :aggregate_failures do
      reconfigure(seed_after_create: true,
                  tenant_privilege_policy: ->(_ctx) { raise(ArgumentError, 'boom') })
      allow(adapter).to(receive(:seed))

      expect { adapter.create('acme') }.to(raise_error(ArgumentError, 'boom'))

      expect(adapter).not_to(have_received(:seed))
      expect(Apartment::Instrumentation).not_to(have_received(:instrument).with(:create, anything))
    end

    it 'creates the tenant without a policy configured' do
      reconfigure

      expect { adapter.create('acme') }.not_to(raise_error)
      expect(adapter.created_tenants).to(include('acme'))
    end
  end
```

- [ ] **Step 5: Run it to make sure it fails**

Run: `bundle exec rspec spec/unit/adapters/abstract_adapter_spec.rb -e "privilege policy"`
Expected: FAIL — the policy is never called, so `phases` is empty.

- [ ] **Step 6: Wire the invocation**

In `lib/apartment/adapters/abstract_adapter.rb`, replace `#run_tenant_ddl` with:

```ruby
      def run_tenant_ddl(tenant)
        MigrationRole.wrap do
          create_tenant(tenant)
          apply_privilege_policy(tenant, :before_schema_load)
          import_schema(tenant) if Apartment.config.schema_load_strategy
          apply_privilege_policy(tenant, :after_schema_load)
        end
      ensure
        discard_migration_role_pool(tenant)
      end
```

and delete `#grant_tenant_privileges` and the base `#grant_privileges`, adding:

```ruby
      # Invoke the adopter's policy for one phase. Two calls per create, because
      # position is policy: a default-privileges-only model has to record its rules
      # before the schema import or imported tables fall outside them, while a model
      # granting existing objects has to run after. See
      # docs/designs/v4-rbac-contract.md.
      #
      # A fresh context per phase; nothing is shared but the resolved role, which is
      # memoized for the create so the round trip is paid once.
      def apply_privilege_policy(tenant, phase)
        policy = Apartment.config.tenant_privilege_policy
        return unless policy

        conn = ActiveRecord::Base.connection
        @privilege_db_role ||= current_db_role(conn)

        policy.call(
          Privileges::Context.new(
            tenant: tenant,
            container_name: physical_tenant_name(tenant),
            connection: conn,
            db_role: @privilege_db_role,
            phase: phase
          )
        )
      end
```

Clear the memo at the end of `#run_tenant_ddl`'s `ensure`, so a second `create` on the same adapter instance re-resolves:

```ruby
      ensure
        @privilege_db_role = nil
        discard_migration_role_pool(tenant)
      end
```

- [ ] **Step 7: Run the tests**

Run: `bundle exec rspec spec/unit/ && bundle exec rubocop lib spec`
Expected: PASS, no offenses. Existing `#grant_tenant_privileges` examples must already be gone (Task 3, Step 10).

- [ ] **Step 7b: Port the integration specs off `app_role` in this same task**

Originally Task 8's Step 1. Moved here deliberately: removing a config key and updating its call sites belong in one commit. Left in Task 8, the RBAC lane would not merely fail between the two commits — it would raise `NoMethodError` on `c.app_role=` at configure time, and the tree would sit red across a review boundary.

```bash
grep -rln "app_role" spec/
```

In each hit, replace `c.app_role = RbacHelper::ROLES[:app_user]` with:

```ruby
      c.tenant_privilege_policy = Apartment::Privileges.standard(grant_to: RbacHelper::ROLES[:app_user])
```

Then run the lane:

Run: `DATABASE_ENGINE=postgresql bundle exec appraisal rails-8.1-postgresql rspec spec/integration/v4/ --tag rbac`
Expected: `24 examples, 0 failures, 4 pending`. These five examples went red at the end of Task 3 — `migrator_rbac_spec.rb:87`, `rbac_grants_spec.rb:61`, `:96`, `:119`, and `create_migration_role_spec.rb:67` — because the String form fell through to the base no-op once the adapter overrides were gone. They assert on effective privileges rather than on statements, so a correct port turns all five green without touching an assertion. If one stays red, the phase mapping in Task 3 is wrong; fix the mapping, not the spec.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "Feat(v4): replace app_role with a two-phase tenant_privilege_policy

app_role was a privilege policy wearing a config key. Its String form issued six
statements on PostgreSQL schemas, one with different semantics on MySQL, and
nothing at all on two adapters, so one key had four behaviours and an adopter had
no way to learn which they got. It was also singular by construction and could
not express FOR ROLE, which is the join the create/migrate role bug turned on.

tenant_privilege_policy is a callable invoked once per phase inside the ddl_role
wrap, receiving a context that carries the physical container name and the
resolved database role. Two phases because position is policy: a
default-privileges-only model must record its rules before the schema import,
and a model granting existing objects must run after. The role is resolved once
per create, not once per phase.

Removed with no shim: pre-GA, and the String form's silent no-op on two adapters
was itself the defect."
```

---

### Task 6: Translate an unresolvable `ddl_role`

**Files:**
- Modify: `lib/apartment/migration_role.rb`
- Test: `spec/unit/migration_role_spec.rb` (create)

**Interfaces:**
- Consumes: `Apartment.config.ddl_role` (Task 1).
- Produces: `MigrationRole.wrap` raises `Apartment::ConfigurationError` when the role has no ActiveRecord registration, with the original error as `#cause`.

- [ ] **Step 1: Write the failing test**

Create `spec/unit/migration_role_spec.rb`:

```ruby
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe(Apartment::MigrationRole) do
  def configure(role)
    Apartment.configure do |c|
      c.tenant_strategy = :schema
      c.tenants_provider = -> { [] }
      c.default_tenant = 'public'
      c.ddl_role = role
    end
  end

  it 'yields without connected_to when no role is configured' do
    configure(nil)
    expect(ActiveRecord::Base).not_to(receive(:connected_to))

    expect(described_class.wrap { :ran }).to(eq(:ran))
  end

  it 'wraps in connected_to when a role is configured' do
    configure(:db_manager)
    expect(ActiveRecord::Base).to(receive(:connected_to).with(role: :db_manager).and_yield)

    described_class.wrap { :ran }
  end

  # The check is here rather than at activate! because activate! runs in
  # after_initialize, which fires after the eager-load initializer — so under lazy
  # loading (development, most test setups) no model has run connects_to yet and a
  # boot-time check would fail on every boot.
  it 'translates an unresolvable role into a ConfigurationError naming the key', :aggregate_failures do
    configure(:nope)
    allow(ActiveRecord::Base).to(receive(:connected_to)
      .and_raise(ActiveRecord::ConnectionNotDefined, 'No connection pool for role :nope'))

    raised = nil
    begin
      described_class.wrap { :never }
    rescue StandardError => e
      raised = e
    end

    expect(raised).to(be_a(Apartment::ConfigurationError))
    expect(raised.message).to(match(/ddl_role.*:nope/))
    expect(raised.cause).to(be_a(ActiveRecord::ConnectionNotDefined))
  end

  it 'does not swallow an error raised by the block itself' do
    configure(:db_manager)
    allow(ActiveRecord::Base).to(receive(:connected_to).and_yield)

    expect { described_class.wrap { raise(ArgumentError, 'from the block') } }
      .to(raise_error(ArgumentError, 'from the block'))
  end

  # THIS is the example that exercises the `entered` guard. The one above does not:
  # ArgumentError never reaches the rescue clause, so `entered` is never consulted
  # on that path and the example passes with the guard removed. Here the block raises
  # the SAME class the rescue catches, which is the only way to tell "could not enter
  # the role" apart from "the block failed inside it".
  it 'does not blame ddl_role for a connection error the block itself raised' do
    configure(:db_manager)
    allow(ActiveRecord::Base).to(receive(:connected_to).and_yield)

    expect { described_class.wrap { raise(ActiveRecord::ConnectionNotEstablished, 'from the block') } }
      .to(raise_error(ActiveRecord::ConnectionNotEstablished, 'from the block'))
  end
end
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `bundle exec rspec spec/unit/migration_role_spec.rb`
Expected: the translation example FAILS with `ActiveRecord::ConnectionNotDefined`; the others pass.

- [ ] **Step 3: Implement the translation**

In `lib/apartment/migration_role.rb`:

```ruby
    def wrap(&)
      role = Apartment.config.ddl_role
      return yield unless role

      begin
        ActiveRecord::Base.connected_to(role: role, &)
      rescue ActiveRecord::ConnectionNotDefined, ActiveRecord::ConnectionNotEstablished => e
        raise(Apartment::ConfigurationError,
              "ddl_role is set to #{role.inspect} but ActiveRecord has no connection " \
              'registered for that role. Declare it with connects_to on your ' \
              "application record, or unset ddl_role. (#{e.class}: #{e.message})")
      end
    end
```

The `rescue` must not wrap errors raised inside the block. `connected_to` calls the block, so an `ActiveRecord::ConnectionNotEstablished` from a query *inside* the block would be caught here too. Guard by resolving the role before yielding:

```ruby
    def wrap(&)
      role = Apartment.config.ddl_role
      return yield unless role

      begin
        ActiveRecord::Base.connected_to(role: role) { nil }
      rescue ActiveRecord::ConnectionNotDefined, ActiveRecord::ConnectionNotEstablished => e
        raise(Apartment::ConfigurationError,
              "ddl_role is set to #{role.inspect} but ActiveRecord has no connection " \
              'registered for that role. Declare it with connects_to on your ' \
              "application record, or unset ddl_role. (#{e.class}: #{e.message})")
      end

      ActiveRecord::Base.connected_to(role: role, &)
    end
```

That probe costs a second `connected_to` on every wrap. Prefer instead to let the block's own errors pass through by tagging them:

```ruby
    def wrap(&)
      role = Apartment.config.ddl_role
      return yield unless role

      entered = false
      ActiveRecord::Base.connected_to(role: role) do
        entered = true
        yield
      end
    rescue ActiveRecord::ConnectionNotDefined, ActiveRecord::ConnectionNotEstablished => e
      raise if entered

      raise(Apartment::ConfigurationError,
            "ddl_role is set to #{role.inspect} but ActiveRecord has no connection " \
            'registered for that role. Declare it with connects_to on your ' \
            "application record, or unset ddl_role. (#{e.class}: #{e.message})")
    end
```

Use this third form: one `connected_to`, and `entered` distinguishes "could not enter the role" from "the block failed". Add the fourth example above to lock that distinction.

- [ ] **Step 4: Run the tests**

Run: `bundle exec rspec spec/unit/migration_role_spec.rb spec/unit/migrator_spec.rb`
Expected: PASS.

- [ ] **Step 5: Probe non-vacuity**

Temporarily change `raise if entered` to `raise if false` and re-run. Exactly ONE example must fail: **"does not blame ddl_role for a connection error the block itself raised"** — the fifth one, whose block raises a class the rescue actually catches. Restore it, re-run, confirm 5 examples pass.

Do not use the fourth example as the probe target. An earlier version of this plan did, and it cannot fail: `ArgumentError` never reaches the rescue clause, so `entered` is never consulted and the example is green with the guard deleted. Verified by running it. A probe that cannot fail is worse than no probe, because it certifies the guard while testing nothing.

Note also that `ActiveRecord::ConnectionNotDefined` subclasses `ConnectionNotEstablished`, so naming both in the rescue is redundant. Keep both anyway: the narrower class is what an unregistered role actually raises, and naming it documents the case.

- [ ] **Step 6: Commit**

```bash
git add lib/apartment/migration_role.rb spec/unit/migration_role_spec.rb
git commit -m "Feat(v4): name ddl_role in the error when its role is unregistered

A misconfigured ddl_role surfaced as an ActiveRecord pool-resolution failure with
no mention of Apartment or the key that caused it. Translated at the wrap, which
is the first place the role is used.

Not at activate!: that runs in after_initialize, which fires after the eager-load
initializer, so under lazy loading no model has run connects_to yet and a
boot-time check would fail on every development boot.

The rescue distinguishes failing to enter the role from the block failing inside
it, so a query error from the caller's own code still surfaces as itself."
```

---

### Task 7: Run `drop_tenant` on `ddl_role`

**Files:**
- Modify: `lib/apartment/adapters/abstract_adapter.rb` (`#drop`)
- Test: `spec/unit/adapters/abstract_adapter_spec.rb`

**Interfaces:**
- Consumes: `MigrationRole.wrap`.
- Produces: `#drop` executes `drop_tenant` inside the wrap; pool removal and shard deregistration stay outside it.

- [ ] **Step 1: Write the failing test**

Add to `spec/unit/adapters/abstract_adapter_spec.rb`:

```ruby
  describe '#drop and the DDL role' do
    before { allow(Apartment::Instrumentation).to(receive(:instrument)) }

    # DROP SCHEMA requires ownership, and the container is owned by ddl_role, so a
    # writing role generally cannot drop what the gem created.
    it 'drops the container inside the DDL role' do
      reconfigure(ddl_role: :db_manager)
      depth = 0
      allow(ActiveRecord::Base).to(receive(:connected_to)) do |role:, &block|
        expect(role).to(eq(:db_manager))
        depth += 1
        begin
          block.call
        ensure
          depth -= 1
        end
      end
      observed = nil
      allow(adapter).to(receive(:drop_tenant) { observed = depth })

      adapter.drop('acme')

      expect(observed).to(eq(1))
    end

    it 'keeps pool bookkeeping outside the wrap' do
      reconfigure(ddl_role: :db_manager)
      current_depth, = role_depth_tracker
      depths = {}
      allow(adapter).to(receive(:drop_tenant) { depths[:drop_tenant] = current_depth.call })
      pool_manager = instance_double(Apartment::PoolManager)
      allow(pool_manager).to(receive(:remove_tenant) { depths[:remove_tenant] = current_depth.call; [] })
      allow(Apartment).to(receive(:pool_manager).and_return(pool_manager))

      adapter.drop('acme')

      expect(depths).to(eq(drop_tenant: 1, remove_tenant: 0))
    end
  end
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `bundle exec rspec spec/unit/adapters/abstract_adapter_spec.rb -e "drop and the DDL role"`
Expected: the first example FAILS with `observed` at 0 — `drop_tenant` runs outside any wrap today.

Use the same `role_depth_tracker` helper shape the create-path examples in that file already use, and assert on a recorded depth map. An earlier version of this plan put an `expect` inside the `remove_tenant` stub instead; that is worse in two ways — a failure surfaces from inside a stub during `adapter.drop` rather than at an assertion, and if `remove_tenant` were never called the assertion would silently not run, which is why it needed a trailing `have_received` to shore it up. Its discrimination also rested on the tracking variable being `nil` before the wrap and `false` after, an accident of initialization rather than a stated fact.

- [ ] **Step 3: Wrap the engine call only**

In `#drop`, replace the bare `drop_tenant(tenant)` with:

```ruby
        # Wrapped for the same reason create is: the container is owned by ddl_role,
        # and DROP SCHEMA requires ownership. Only the engine call — the pool removal
        # and shard deregistration below are local bookkeeping and need no role.
        MigrationRole.wrap { drop_tenant(tenant) }
```

- [ ] **Step 4: Run the tests**

Run: `bundle exec rspec spec/unit/ && bundle exec rubocop lib spec`
Expected: PASS, no offenses.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "Fix(v4): drop tenants on ddl_role

Create runs on ddl_role and drop did not, which is asymmetric in the direction
that fails: DROP SCHEMA requires ownership and the container is owned by
ddl_role, so a writing role generally cannot drop what the gem created. Only the
engine call is wrapped; the pool removal and shard deregistration after it are
local bookkeeping.

Behaviour change for anyone dropping tenants today on a role that happens to hold
the privilege."
```

---

### Task 8: Integration coverage

**Files:**
- Create: `spec/integration/v4/tenant_privilege_policy_spec.rb`
- Modify: `spec/integration/v4/rbac_grants_spec.rb` (it configures the removed `app_role`)
- Modify: `spec/integration/v4/migrator_rbac_spec.rb`, `spec/integration/v4/postgresql_database_rbac_spec.rb`, `spec/integration/v4/mysql_rbac_grants_spec.rb` (same)

**Interfaces:**
- Consumes: everything above; `RbacHelper` from `spec/integration/v4/support/rbac_helper.rb`.
- Produces: no library code.

The port of the existing specs off `app_role` moved into Task 5, Step 7b — see the note there. This task adds only the new coverage.

- [ ] **Step 1: Confirm the lane is green before you add to it**

Run: `DATABASE_ENGINE=postgresql bundle exec appraisal rails-8.1-postgresql rspec spec/integration/v4/ --tag rbac`
Expected: `24 examples, 0 failures, 4 pending`. If it is red, Task 5 is incomplete; finish it before adding examples.

- [ ] **Step 3: Write the new integration spec**

Create `spec/integration/v4/tenant_privilege_policy_spec.rb`, modelled on `spec/integration/v4/create_migration_role_spec.rb`. The two examples that matter:

```ruby
  # The regression a single post-import call site would have introduced. A policy
  # of nothing but default-privileges rules covers imported tables only because the
  # rules are recorded BEFORE the import.
  it 'covers schema-imported tables with a default-privileges-only policy' do
    # configure schema_load_strategy with a schema file creating one table, and a
    # policy issuing only the three ALTER DEFAULT PRIVILEGES rules at
    # :before_schema_load, then assert the app role can INSERT into the imported
    # table.
  end

  # The reconciliation gap made visible. Out of scope to fix; in scope to pin, so
  # nobody "simplifies" FOR ROLE back out of the statements.
  it 'keeps grants correct when the executing role differs from the recorded grantor' do
    # create with FOR ROLE naming ctx.db_role, then create a table as a DIFFERENT
    # elevated role, and assert the app role still cannot read it — the rule is
    # scoped to the role named, which is the point.
  end
```

Fill both in against the real database following the setup in `create_migration_role_spec.rb`. Do not leave them pending.

- [ ] **Step 4: Probe non-vacuity**

For the first example, temporarily change the PostgreSQL statement builder to emit the default-privileges rules at `:after_schema_load` instead. Re-run: the example must FAIL. Restore, confirm PASS.

- [ ] **Step 5: Run every lane**

```bash
bundle exec rspec spec/unit/
DATABASE_ENGINE=postgresql bundle exec appraisal rails-8.1-postgresql rspec spec/integration/v4/
bundle exec appraisal rails-8.1-sqlite3 rspec spec/integration/v4/
bundle exec rubocop lib spec
```
Expected: all PASS, no offenses. Run the MySQL lane too if a local MySQL is available.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "Test(v4): cover the two-phase privilege policy against real roles

Ports the RBAC lane off the removed app_role, and adds the two examples the
design turns on: a default-privileges-only policy covers schema-imported tables
because its rules are recorded before the import, and an explicit FOR ROLE stays
correct when the executing role changes. Both were probed by neutering the
behaviour and watching them fail."
```

---

### Task 9: Documentation

**Files:**
- Create: `docs/rbac.md`
- Modify: `README.md` (RBAC section), `CLAUDE.md` (Gotchas), `lib/apartment/CLAUDE.md`, `lib/apartment/adapters/CLAUDE.md`, `docs/designs/v4-phase5-rbac-roles-schema-cache.md` (supersede notice), `lib/generators/apartment/install/templates/apartment.rb`

**Interfaces:** none.

- [ ] **Step 1: Write `docs/rbac.md`**

One line per paragraph, no hard wrapping. It must state, each with a worked example:

The single rule, quoted from the spec's contract section.

The `Privileges.standard` recipe for PostgreSQL schema-per-tenant and for MySQL database-per-tenant.

Writing a custom policy: the context's fields, that `container_name` is the name to address and `quoted_container` the one to interpolate, that `next` is the idiom for branching on phase, and that the connection must not be retained.

The MySQL prerequisite: `CREATE DATABASE` conveys no `GRANT OPTION`, so either `ddl_role` holds it or the policy opens its own connection under a role that does. The second is supported.

That PostgreSQL database-per-tenant and SQLite have no standard policy and why.

The failure contract: a raising policy aborts the create and skips seeding; retry is safe before the schema import and is drop-and-recreate after it; the tenant must not become routable until create returns.

That row-level security on tables added by later migrations belongs in those migrations, because no create-time hook can reach them.

- [ ] **Step 2: Update the README RBAC section**

Replace the `migration_role` / `app_role` paragraphs with `ddl_role` and `tenant_privilege_policy`, the `Privileges.standard` one-liner, and a link to `docs/rbac.md`. Delete the "Set both or neither" paragraph — it described the coupling this work removes.

- [ ] **Step 3: Update the CLAUDE.md files**

In the root `CLAUDE.md` Gotchas, replace the "All tenant DDL runs on `migration_role`" entry with one covering the new contract: `ddl_role` including drop, the two phases and why position is policy, `ConfigurationError` rather than `NotImplementedError` and the `ScriptError` reason, and the context being a plain class rather than `Data`. Keep it to one entry.

In `lib/apartment/CLAUDE.md`, add `privileges.rb` and `privileges/context.rb` to the directory listing and a short section for each. Update the `migration_role.rb` section for the rename and the error translation.

In `lib/apartment/adapters/CLAUDE.md`, replace the create-path paragraph with the new sequence and document `#standard_privilege_statements` and `#current_db_role` as the seams a custom adapter implements.

- [ ] **Step 4: Add the supersede notice**

At the top of `docs/designs/v4-phase5-rbac-roles-schema-cache.md`, under the existing status line:

```markdown
> **Superseded in part.** The `migration_role` and `app_role` sections below, and the Key Invariant, are superseded by [`v4-rbac-contract.md`](v4-rbac-contract.md). `migration_role` is now `ddl_role`, `app_role` is removed, and privilege policy belongs to the adopter. The schema-cache and `PendingMigrationError` sections still stand.
```

- [ ] **Step 5: Update the generator template**

In `lib/generators/apartment/install/templates/apartment.rb`, replace the `app_role` commented line with:

```ruby
  # config.tenant_privilege_policy  = nil   # e.g. Apartment::Privileges.standard(grant_to: 'app_user')
```

- [ ] **Step 6: Verify no stale references remain**

```bash
grep -rn "app_role" lib spec docs README.md CLAUDE.md
grep -rn "migration_role" lib spec docs README.md CLAUDE.md | grep -v with_migration_role
```
Expected: hits only in `docs/designs/` prose describing history, and `with_migration_role` as a method name.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "Docs: document the RBAC contract for adopters

docs/rbac.md states the single rule, the standard recipes per engine, how to
write a custom policy, the MySQL GRANT OPTION prerequisite, the failure contract,
and why row-level security on migration-added tables belongs in those migrations.

Marks the phase 5 design's migration_role and app_role sections superseded,
including the Key Invariant that called the create/migrate role coupling
self-enforcing."
```

---

## Self-review

**Spec coverage.** Contract → Tasks 1, 5, 7. Surface → Tasks 1, 5. Removals → Tasks 3, 5. Context object → Task 2. Two phases → Tasks 3, 5. Standard-grants helper → Tasks 3, 4. Validation → Tasks 1, 4, 5, 6. Failure semantics → Task 5 (abort/no-seed) and Task 9 (the retry contract, which is documentation, not code). Per-engine notes → Tasks 3, 9. Migrating from `app_role` → Tasks 8, 9. Identifier quoting → Tasks 2, 3. Out of scope stays out: no reconciliation task, no per-principal identity task.

**Two gaps found and closed while reviewing.** The spec says the `:create` callback chain still wraps the whole operation; no task changes it, and Task 5's diff leaves `run_callbacks(:create)` where it is, so this is correct by omission — Task 9, Step 3 documents it. And `Privileges.standard` needs `Apartment.adapter` to be set, which is true during a create but not at `configure` time; the factory only captures arguments and resolves the adapter at call time, which Task 4's implementation does and its test pins by stubbing `Apartment.adapter`.

**Type consistency.** `standard_privilege_statements(ctx, grant_to:, include_functions:)` has the same signature in Tasks 3 and 4. `Context.new` takes the same five keywords in Tasks 2, 3, and 5. `current_db_role(connection)` is consistent in Tasks 3 and 5. `MigrationRole.wrap` is used, never `with_migration_role`, outside `Migrator`.

**One ordering constraint worth restating.** Task 3 deletes the adapter `grant_privileges` methods while `AbstractAdapter#grant_tenant_privileges` still calls them; Task 5 removes the caller. Between those commits `bundle exec rspec spec/unit/` fails unless Task 3 Step 10's deletion of the old examples is done. Tasks 3 and 5 must land in that order, and neither should be split across a review boundary that leaves the tree red.
