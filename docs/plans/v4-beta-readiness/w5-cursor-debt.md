# W5 — Cursor Debt: Physical-Name Validation + Advisory-Lock Fragility Guard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close two residual Cursor PR-review items that the beta-readiness roadmap (W5) gates on: (1) the tenant pool-resolution path validates the *raw* tenant name instead of the physical identifier `create` validates; (2) `Migrator#with_advisory_locks_disabled` pokes a private ActiveRecord ivar with no guard, so a future Rails rename would silently re-enable advisory locks and serialize parallel tenant migrations.

**Architecture:** Item 1 introduces an overridable `physical_tenant_name(tenant)` seam on `AbstractAdapter` (default `environmentify(tenant)`, the database name for database-per-tenant strategies); `validated_connection_config` validates that name. `PostgresqlSchemaAdapter` overrides it to the raw tenant (schemas are named directly, never environmentified). Item 2 wraps the ivar poke in `instance_variable_defined?` guards: if the ivar is absent it warns and proceeds (graceful degradation — migrations stay correct, just serialized) instead of creating a silent orphan ivar, and a contract unit test against a real in-memory connection breaks CI if Rails ever renames the ivar.

**Tech Stack:** Ruby 3.3+, Rails 7.2/8.0/8.1 (ActiveRecord), RSpec, RuboCop. No new dependencies.

## Global Constraints

- **Ruby** `>= 3.3`; **Rails** `7.2 / 8.0 / 8.1` (and `main` canary). Code must pass on all.
- **RuboCop**: run `bundle exec rubocop` on every changed file (implementation AND specs) before any push; zero new offenses.
- **No CampusESP/private references** in code, specs, comments, or commit messages — this is a public OSS gem.
- **Commit style**: new commits (never amend); this work runs on a feature branch off `main` (NOT off the current `docs/v4-beta-readiness` branch).
- **`validated_connection_config` is a template method** — subclasses must NOT override it; they override the `physical_tenant_name` seam instead.
- **Minimal blast radius**: do NOT change `create`'s validation in this work. Item 1 is scoped to the pool-resolution path only.

---

## Pre-flight: branch

- [ ] **Step 0: Create the feature branch off `main`**

```bash
cd /Users/mauricionovelo/dev/CampusESP/apartment
git fetch origin main --quiet
git checkout -b feat/v4-w5-cursor-debt origin/main
git branch --show-current   # expect: feat/v4-w5-cursor-debt
```

---

## File Structure

- `lib/apartment/adapters/abstract_adapter.rb` — add `physical_tenant_name`; route `validated_connection_config`'s validation through it. (Modify)
- `lib/apartment/adapters/postgresql_schema_adapter.rb` — override `physical_tenant_name` to return the raw tenant. (Modify)
- `lib/apartment/migrator.rb` — guard `with_advisory_locks_disabled`'s ivar poke; add the ivar-name constant. (Modify)
- `spec/unit/adapters/abstract_adapter_spec.rb` — physical-name validation example. (Modify)
- `spec/unit/adapters/postgresql_schema_adapter_spec.rb` — raw-name override example. (Modify)
- `spec/unit/migrator_spec.rb` — update the three connection-mock `before` blocks; add absent-ivar warn example + ivar-contract example. (Modify)

---

## Task 1: `physical_tenant_name` seam — pool-resolution validates the physical identifier

**Files:**
- Modify: `lib/apartment/adapters/abstract_adapter.rb` (add `physical_tenant_name` after `environmentify` ~line 200; change validation in `validated_connection_config` line 28)
- Modify: `lib/apartment/adapters/postgresql_schema_adapter.rb` (add `physical_tenant_name` override)
- Test: `spec/unit/adapters/abstract_adapter_spec.rb`
- Test: `spec/unit/adapters/postgresql_schema_adapter_spec.rb`

**Interfaces:**
- Produces: `AbstractAdapter#physical_tenant_name(tenant) -> String` — default returns `environmentify(tenant)`.
- Produces: `PostgresqlSchemaAdapter#physical_tenant_name(tenant) -> String` — returns `tenant.to_s`.
- Consumes: existing `AbstractAdapter#environmentify(tenant)` (returns the env-prefixed/suffixed name, or `tenant.to_s` when `environmentify_strategy` is nil), and `TenantNameValidator.validate!(name, strategy:, adapter_name:)`.

- [ ] **Step 1: Write the failing test (base adapter validates the environmentified physical name)**

In `spec/unit/adapters/abstract_adapter_spec.rb`, inside `describe '#validated_connection_config' do` (after the `tenant_pool_size` context, before the closing `end` at line 120), add:

```ruby
    context 'physical-name validation (pool-resolution path)' do
      # validated_connection_config validates the *physical* tenant identifier
      # (the database name for database-per-tenant strategies) — the
      # environmentified name in the base adapter, matching what create uses.
      # Regression guard: it previously validated the raw tenant, so an invalid
      # environmentified name slipped through pool resolution.
      it 'validates the environmentified name, not the raw tenant' do
        reconfigure(environmentify_strategy: ->(t) { "#{t}\x00" })
        expect { adapter.validated_connection_config('acme') }
          .to(raise_error(Apartment::ConfigurationError, /NUL byte/))
      end
    end
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
bundle exec rspec spec/unit/adapters/abstract_adapter_spec.rb -e "validates the environmentified name"
```
Expected: FAIL — no error raised (current code validates the raw `'acme'`, which is clean, so `validated_connection_config` returns a config hash instead of raising).

- [ ] **Step 3: Add the seam and route validation through it**

In `lib/apartment/adapters/abstract_adapter.rb`, add the method immediately after `environmentify` (after its `end`, ~line 200):

```ruby
      # The physical identifier used to address this tenant at connection time:
      # the database name for database-per-tenant strategies (environmentified).
      # validated_connection_config validates THIS name so the pool-resolution
      # path agrees with what the connection actually targets. Schema-per-tenant
      # overrides this to the raw tenant (schemas are named directly).
      def physical_tenant_name(tenant)
        environmentify(tenant)
      end
```

Then change the validation call inside `validated_connection_config` (line 28) from the raw `tenant` to the seam:

```ruby
      def validated_connection_config(tenant, base_config_override: nil)
        effective_base = base_config_override || base_config
        TenantNameValidator.validate!(
          physical_tenant_name(tenant),
          strategy: Apartment.config.tenant_strategy,
          adapter_name: effective_base['adapter']
        )
        config = resolve_connection_config(tenant, base_config: effective_base)
        apply_tenant_pool_size(config)
      end
```

(Leave `create`'s validation at line 45 unchanged — out of scope for W5.)

- [ ] **Step 4: Run the test to verify it passes**

```bash
bundle exec rspec spec/unit/adapters/abstract_adapter_spec.rb -e "validates the environmentified name"
```
Expected: PASS.

- [ ] **Step 5: Write the failing test (schema adapter validates the RAW name)**

In `spec/unit/adapters/postgresql_schema_adapter_spec.rb`, add after the `describe '#validated_connection_config with base_config_override'` block (it ends near line 350; place this new `describe` after it):

```ruby
  describe '#physical_tenant_name' do
    # Schema-per-tenant names schemas directly, so pool-resolution validates and
    # uses the RAW tenant even when environmentify_strategy is set — unlike the
    # database-per-tenant adapters, which validate the environmentified name.
    it 'validates the raw tenant name, ignoring environmentify_strategy' do
      reconfigure(environmentify_strategy: ->(t) { "#{t}\x00" })
      expect { adapter.validated_connection_config('acme') }.not_to(raise_error)
    end

    it 'resolves the search_path from the raw tenant name' do
      reconfigure(environmentify_strategy: ->(t) { "#{t}_ignored" })
      config = adapter.validated_connection_config('acme')
      expect(config['schema_search_path']).to(eq('"acme"'))
    end
  end
```

- [ ] **Step 6: Run the test to verify it fails**

```bash
bundle exec rspec spec/unit/adapters/postgresql_schema_adapter_spec.rb -e "#physical_tenant_name"
```
Expected: FAIL on the first example — the base `physical_tenant_name` returns `environmentify('acme')` = `"acme\x00"`, which raises `/NUL byte/`, so `not_to raise_error` fails. (The second example passes already because `resolve_connection_config` uses raw `tenant`; the first is the one that drives the override.)

- [ ] **Step 7: Add the schema-adapter override**

In `lib/apartment/adapters/postgresql_schema_adapter.rb`, add inside the class (e.g. immediately after `resolve_connection_config`, before the `failsafe_error_classes` comment block):

```ruby
      # Schemas are named directly (never environmentified), so the physical
      # identifier validated at pool-resolution time is the raw tenant name.
      def physical_tenant_name(tenant)
        tenant.to_s
      end
```

- [ ] **Step 8: Run the schema-adapter tests to verify they pass**

```bash
bundle exec rspec spec/unit/adapters/postgresql_schema_adapter_spec.rb -e "#physical_tenant_name"
```
Expected: PASS (both examples).

- [ ] **Step 9: Run the full adapter unit suite (no regressions)**

```bash
bundle exec rspec spec/unit/adapters/
```
Expected: all green. (Confirms the seam didn't disturb existing `validated_connection_config` / create / resolve examples across the abstract, schema, database, mysql2, and sqlite3 specs.)

- [ ] **Step 10: RuboCop the changed files**

```bash
bundle exec rubocop lib/apartment/adapters/abstract_adapter.rb \
  lib/apartment/adapters/postgresql_schema_adapter.rb \
  spec/unit/adapters/abstract_adapter_spec.rb \
  spec/unit/adapters/postgresql_schema_adapter_spec.rb
```
Expected: no offenses.

- [ ] **Step 11: Commit**

```bash
git add lib/apartment/adapters/abstract_adapter.rb \
  lib/apartment/adapters/postgresql_schema_adapter.rb \
  spec/unit/adapters/abstract_adapter_spec.rb \
  spec/unit/adapters/postgresql_schema_adapter_spec.rb
git commit -m "Fix(v4): validate the physical tenant name on the pool-resolution path

validated_connection_config validated the raw tenant while create validates
the physical (environmentified) identifier, so an invalid environmentified
name could slip through pool resolution on database-per-tenant strategies.
Add an overridable physical_tenant_name seam (default environmentify);
PostgresqlSchemaAdapter overrides it to the raw tenant since schemas are
named directly. Closes a Cursor PR-review item (W5).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Advisory-lock fragility guard

**Files:**
- Modify: `lib/apartment/migrator.rb` (`with_advisory_locks_disabled`, lines 216-223; add ivar constant)
- Test: `spec/unit/migrator_spec.rb` (three `before` blocks at ~lines 148, 352, 450; add two examples)

**Interfaces:**
- Produces: `Apartment::Migrator::ADVISORY_LOCKS_IVAR = :@advisory_locks_enabled` (private constant).
- Behavior: `with_advisory_locks_disabled` yields with the leased connection's advisory locks disabled when the ivar is present; when absent it warns (message matching `/cannot disable advisory locks/i`) and yields without poking.
- Consumes: `ActiveRecord::Base.lease_connection`; the connection's `instance_variable_defined?`, `instance_variable_get`, `instance_variable_set`.

- [ ] **Step 1: Update the existing connection mocks so the ivar reads as defined**

The guard added in Step 3 calls `instance_variable_defined?(:@advisory_locks_enabled)`. A plain `double('connection')` returns `false` for that, which would route every example down the warn-and-yield branch and break the existing advisory-lock expectations. In `spec/unit/migrator_spec.rb`, in EACH `before` block that stubs `mock_connection` (there are three — under `describe '#run'` ~line 148, and the two later contexts ~lines 352 and 450), add this line alongside the existing `instance_variable_get` / `instance_variable_set` stubs:

```ruby
      allow(mock_connection).to(receive(:instance_variable_defined?)
        .with(:@advisory_locks_enabled).and_return(true))
```

So each affected `before` reads (the new line added after the existing `instance_variable_set` stub):

```ruby
      allow(ActiveRecord::Base).to(receive_messages(connection_pool: mock_pool, lease_connection: mock_connection))
      allow(mock_connection).to(receive(:instance_variable_get).and_return(true))
      allow(mock_connection).to(receive(:instance_variable_set))
      allow(mock_connection).to(receive(:instance_variable_defined?)
        .with(:@advisory_locks_enabled).and_return(true))
```

- [ ] **Step 2: Write the failing test (absent-ivar warns and still yields)**

In `spec/unit/migrator_spec.rb`, inside the `describe '#run'` block (after the existing "disables advisory locks for tenant migrations and restores afterward" example at line 221), add:

```ruby
    it 'warns and still runs migrations when the connection lacks the advisory-lock ivar' do
      allow(mock_connection).to(receive(:instance_variable_defined?)
        .with(:@advisory_locks_enabled).and_return(false))
      expect(migrator).to(receive(:warn).with(/cannot disable advisory locks/i).at_least(:once))
      result = migrator.run
      expect(result).to(be_a(Apartment::Migrator::MigrationRun))
    end
```

- [ ] **Step 3: Run the test to verify it fails**

```bash
bundle exec rspec spec/unit/migrator_spec.rb -e "warns and still runs migrations when the connection lacks"
```
Expected: FAIL — current `with_advisory_locks_disabled` ignores `instance_variable_defined?` and calls `instance_variable_set` unconditionally; no `warn` is emitted, so the `receive(:warn)` expectation fails.

- [ ] **Step 4: Implement the guard**

In `lib/apartment/migrator.rb`, add the constant near the top of the class body (after the `class Migrator` line / alongside other constants), then replace `with_advisory_locks_disabled` (lines 216-223):

Add the constant (place with the class's other top-level constants):

```ruby
    # ActiveRecord exposes no public setter for advisory-lock state (only the
    # advisory_locks_enabled? reader), so we toggle this private ivar directly.
    # The guard in with_advisory_locks_disabled detects a future Rails rename.
    ADVISORY_LOCKS_IVAR = :@advisory_locks_enabled
```

Replace the method:

```ruby
    # Disable advisory locks on the leased connection for the duration of the
    # block, then restore the original value. lease_connection returns the same
    # connection object for the current thread (fiber-local via IsolatedExecutionState).
    #
    # PG's advisory locks are database-wide and would serialize parallel tenant
    # migrations (issue #298). Rails offers no public setter, so we poke the
    # private @advisory_locks_enabled ivar. The instance_variable_defined? guard
    # makes a future Rails rename visible: rather than silently creating an
    # orphan ivar (leaving locks enabled and serializing migrations), we warn and
    # proceed. The ivar contract is also unit-tested against a real connection.
    def with_advisory_locks_disabled
      conn = ActiveRecord::Base.lease_connection
      unless conn.instance_variable_defined?(ADVISORY_LOCKS_IVAR)
        warn "[Apartment::Migrator] ActiveRecord connection #{conn.class} does not define " \
             "#{ADVISORY_LOCKS_IVAR}; cannot disable advisory locks for this Rails version. " \
             'Parallel tenant migrations will serialize on the database-wide advisory lock.'
        return yield
      end
      original = conn.instance_variable_get(ADVISORY_LOCKS_IVAR)
      conn.instance_variable_set(ADVISORY_LOCKS_IVAR, false)
      yield
    ensure
      if conn&.instance_variable_defined?(ADVISORY_LOCKS_IVAR)
        conn.instance_variable_set(ADVISORY_LOCKS_IVAR, original)
      end
    end
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
bundle exec rspec spec/unit/migrator_spec.rb -e "warns and still runs migrations when the connection lacks"
```
Expected: PASS.

- [ ] **Step 6: Write the ivar-contract test (CI rename detection)**

In `spec/unit/migrator_spec.rb`, add a new top-level `describe` inside the `RSpec.describe(Apartment::Migrator)` block (place it after the `#run` describe):

```ruby
  describe 'advisory-lock ivar contract' do
    # with_advisory_locks_disabled pokes the private @advisory_locks_enabled
    # ivar because Rails has no public setter. This locks the contract: if a
    # future Rails renames the ivar, this fails in CI instead of silently
    # serializing parallel tenant migrations (issue #298). Uses a real
    # in-memory SQLite connection; skips gracefully if the adapter is absent.
    it 'a real ActiveRecord connection defines @advisory_locks_enabled' do
      ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
      conn = ActiveRecord::Base.lease_connection
      expect(conn.instance_variable_defined?(Apartment::Migrator::ADVISORY_LOCKS_IVAR)).to(be(true))
    rescue LoadError, ActiveRecord::AdapterNotFound, ActiveRecord::ConnectionNotEstablished => e
      skip("sqlite3 adapter unavailable in this bundle: #{e.class}")
    ensure
      ActiveRecord::Base.remove_connection
    end
  end
```

- [ ] **Step 7: Run the contract test to verify it passes**

```bash
bundle exec rspec spec/unit/migrator_spec.rb -e "a real ActiveRecord connection defines"
```
Expected: PASS (the bundled sqlite3 adapter sets `@advisory_locks_enabled` in `AbstractAdapter#initialize`). If sqlite3 is genuinely absent, the example reports as `pending`/skipped — acceptable, not a failure.

- [ ] **Step 8: Run the full migrator unit suite (no regressions)**

```bash
bundle exec rspec spec/unit/migrator_spec.rb
```
Expected: all green — including the original "disables advisory locks ... and restores afterward" example, which now passes because the three `before` blocks report the ivar as defined.

- [ ] **Step 9: RuboCop the changed files**

```bash
bundle exec rubocop lib/apartment/migrator.rb spec/unit/migrator_spec.rb
```
Expected: no offenses.

- [ ] **Step 10: Commit**

```bash
git add lib/apartment/migrator.rb spec/unit/migrator_spec.rb
git commit -m "Fix(v4): guard the advisory-lock ivar poke in Migrator

with_advisory_locks_disabled set the private @advisory_locks_enabled ivar
unconditionally; a future Rails rename would silently create an orphan ivar,
re-enabling advisory locks and serializing parallel tenant migrations (#298).
Guard the poke with instance_variable_defined? — warn and proceed when absent
— and add a contract test against a real connection so a rename breaks CI.
Closes a Cursor PR-review item (W5).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Cross-version verification (before opening the PR)

- [ ] **Step 1: Run the touched unit specs across the Rails matrix**

```bash
bundle exec appraisal install   # first time only
bundle exec appraisal rspec spec/unit/adapters/ spec/unit/migrator_spec.rb
```
Expected: green on rails-7.2 / rails-8.0 / rails-8.1 appraisals (the ivar contract and the seam behavior are stable across all three).

- [ ] **Step 2: Full unit suite once**

```bash
bundle exec rspec spec/unit/
```
Expected: all green.

---

## Self-Review

**1. Spec coverage** — both W5 items are implemented and tested:
- Pool-resolution physical-name validation: Task 1 (base validates environmentified; schema validates raw) — covers the `validated_connection_config` raw-tenant Cursor item.
- Advisory-lock fragility: Task 2 (guard + warn-and-yield + ivar contract test) — covers the advisory-lock ivar Cursor item.

**2. Placeholder scan** — every code step shows complete code; every run step shows the exact command and expected PASS/FAIL. No TBDs.

**3. Type/name consistency** — `physical_tenant_name(tenant)` is defined in `AbstractAdapter` (Task 1 Step 3) and overridden identically-named in `PostgresqlSchemaAdapter` (Step 7); `validated_connection_config` calls it (Step 3). `ADVISORY_LOCKS_IVAR` is defined once (Task 2 Step 4) and referenced by name in the contract test (Step 6). The `/cannot disable advisory locks/i` matcher (Task 2 Step 2) matches the warn string in Step 4.

**4. Scope** — single feature branch, two independent fixes, both small; no `create`-path change, no new public error class, no dependency added.
