# PostgreSQL sequence_name Cross-Tenant Fix — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore the v3 `default_sequence_name` guarantee in v4 so `Model.sequence_name` memoizes a schema-agnostic value and bulk-insert primary-key prefetch (`activerecord-import`'s `nextval(...)`) always draws ids from the current tenant's sequence.

**Architecture:** A prepended module on `ActiveRecord::ConnectionAdapters::PostgreSQLAdapter` (`Apartment::Patches::PostgresqlSequenceName`) strips the connection's own `current_schema` prefix from the value Rails resolves via `pg_get_serial_sequence`, before ActiveRecord memoizes it class-level. Prefixes from *other* schemas (persistent schemas; pinned models' `public.` qualification) are preserved. Registered via `ActiveSupport.on_load(:active_record_postgresqladapter)` at gem load — not in `activate!` — so the boot window before activation is covered and MySQL/SQLite consumers never load `pg`.

**Tech Stack:** Ruby gem (`ros-apartment`), ActiveRecord 7.2/8.x, RSpec (unit + PG-gated integration via appraisal), Zeitwerk.

## Background (why this exists)

Root-cause investigation (2026-07-12, production incident in a consumer app on 4.0.0.alpha7):

- Rails memoizes `Model.sequence_name` **once per model class, process-wide** (`model_schema.rb:387-398`), resolved via `connection.default_sequence_name` → `pg_get_serial_sequence('<unqualified table>', 'id')`, which returns a **schema-qualified** name resolved through the *current connection's* `search_path`.
- Under v4 pool-per-tenant, the first tenant to touch a model class bakes **its** schema into the memoized value. Every later `activerecord-import` prefetch renders a literal `nextval('<first_tenant>.<table>_id_seq')` in **every** tenant → ids from the wrong tenant's number space → silent sequence drift + `PG::UniqueViolation` on collision.
- v3 had `Apartment::PostgreSqlAdapterPatch#default_sequence_name` (stripped the tenant prefix; forced `default_tenant.` prefix for excluded models). It was deleted in Phase 2.5 (`245c074`, PR `#356`) as part of the v3 bulk deletion, with no v4 replacement — collateral, not deliberate.
- Reset-on-switch is **unsound** in v4: multiple tenants are live concurrently in one process, so the only correct memoized value is a schema-agnostic one, re-resolved per connection via `search_path` — the same invariant `docs/designs/v4-connection-model-rationale.md` establishes for tables.
- Pinned models are already safe by routing (PG schema strategy qualifies their table names with `public.` and shares the tenant connection; database strategies pin a pool) — the patch must **preserve** their qualified sequence names. Plain AR inserts are unaffected (PG uses `INSERT ... RETURNING` with the column default).

Consumer-side note (outside this repo): **no application code changes are required** — the gem owns this boundary, and an app-level `self.sequence_name = ...` was considered and rejected (it pushes tenancy back into every model, the exact ownership inversion `v4-connection-model-rationale.md` argues against, and it is a footgun on pinned models, whose sequence must stay qualified). Adopters needing the fix before the release point their Gemfile at the branch. A one-time sequence repair is still required **after** deploying the fix; existing drift does not self-heal.

## Global Constraints

- Branch off `main` (current work branch `feat/pool-connection-budget-observability` must not be the base).
- New PR against `main`; squash & merge (repo convention).
- Version bump to `4.0.0.alpha8` in `lib/apartment/version.rb` lands **in this PR** (RELEASING.md allows the bump in the feature PR that completes the release).
- Every commit that lands on the branch must be green (write specs RED locally, but commit spec + implementation together).
- Run `bundle exec rubocop` on ALL changed files (impl + specs + docs don't need it, but every `.rb` does) before every push.
- Commit message style: `Fix(v4): ...` / `Test(v4): ...` (match `git log` conventions). No AI co-author trailers unless the session harness mandates them.
- Rails support floor is 7.2: `ActiveSupport.on_load(:active_record_postgresqladapter)` (hook exists since 7.1) and `Model.with_connection` (7.2) are both safe.
- v4 does not support JRuby — the v3 patch's JDBC quote-stripping is deliberately not carried over.
- Plans/design docs live in `docs/plans/` / `docs/designs/` (no date prefixes).

---

### Task 0: Branch setup

**Files:** none (git only)

- [ ] **Step 0.1: Create the fix branch off up-to-date main**

```bash
git checkout main && git pull origin main
git checkout -b fix/pg-sequence-name-cross-tenant
```

Expected: new branch at `origin/main` HEAD. (If you need to preserve the current checkout, use the manage-worktree skill instead; working tree is clean so an in-place checkout is fine.)

---

### Task 1: Failing integration spec — cross-tenant prefetch (PG)

**Files:**
- Create: `spec/integration/v4/postgresql_sequence_name_spec.rb`

**Interfaces:**
- Consumes: `V4IntegrationHelper` (`spec/integration/v4/support.rb`) — `ensure_test_database!`, `establish_default_connection!(tmp_dir:)`, `build_adapter(config)`, `cleanup_tenants!(tenants, adapter)`, `postgresql?`.
- Produces: the executable regression contract for Task 3. References `Apartment::Patches::PostgresqlSequenceName` (defined in Task 3).

- [ ] **Step 1.1: Write the spec file**

```ruby
# frozen_string_literal: true

require 'spec_helper'
require_relative 'support'

# Regression spec for the v3→v4 sequence-name regression: ActiveRecord
# memoizes Model.sequence_name once per class, process-wide, resolved
# schema-qualified on whichever tenant's connection touches it first.
# activerecord-import renders that memoized value into a literal
# nextval(...), so every tenant then draws ids from the first tenant's
# sequence. The patch keeps the memoized value schema-agnostic.
RSpec.describe('v4 PostgreSQL sequence_name resolution', :integration,
               skip: (V4_INTEGRATION_AVAILABLE && V4IntegrationHelper.postgresql? ? false : 'requires PostgreSQL')) do
  include V4IntegrationHelper

  let(:tmp_dir) { Dir.mktmpdir('apartment_pg_seq') }
  let(:created_tenants) { [] }

  before do
    V4IntegrationHelper.ensure_test_database!
    config = V4IntegrationHelper.establish_default_connection!(tmp_dir: tmp_dir)

    Apartment.configure do |c|
      c.tenant_strategy = :schema
      c.tenants_provider = -> { [] }
      c.default_tenant = 'public'
      c.check_pending_migrations = false
    end

    Apartment.adapter = V4IntegrationHelper.build_adapter(config)
    Apartment.activate!

    stub_const('SequenceWidget', Class.new(ActiveRecord::Base) do
      self.table_name = 'sequence_widgets'
    end)

    %w[seq_a seq_b].each do |name|
      Apartment.adapter.create(name)
      created_tenants << name
      Apartment::Tenant.switch(name) do
        ActiveRecord::Base.connection.create_table(:sequence_widgets, force: true) do |t|
          t.string(:name)
        end
      end
    end

    # Seed each tenant's sequence to a distinct range so "which sequence
    # produced this id" is unambiguous (fresh sequences both sit at 1).
    { 'seq_a' => 1_000, 'seq_b' => 2_000 }.each do |schema, value|
      ActiveRecord::Base.connection.select_value(
        %(SELECT setval('"#{schema}".sequence_widgets_id_seq', #{value}))
      )
    end
  end

  after do
    V4IntegrationHelper.cleanup_tenants!(created_tenants, Apartment.adapter)
    Apartment.clear_config
    Apartment::Current.reset
  end

  def last_value(schema, sequence: 'sequence_widgets_id_seq')
    ActiveRecord::Base.connection.select_value(
      %(SELECT last_value FROM "#{schema}"."#{sequence}")
    ).to_i
  end

  # Emulates activerecord-import's primary-key prefetch: it renders the
  # memoized Model.sequence_name into a literal nextval() on the model's
  # own connection (import.rb ~1042 + its postgresql adapter).
  def prefetch_id(model)
    model.with_connection do |conn|
      conn.select_value("SELECT nextval('#{model.sequence_name}')").to_i
    end
  end

  it 'prepends the patch onto the PostgreSQL adapter' do
    Apartment::Tenant.switch('seq_a') do
      adapter_class = SequenceWidget.with_connection { |c| c.class }
      expect(adapter_class.ancestors).to include(Apartment::Patches::PostgresqlSequenceName)
    end
  end

  it 'memoizes a schema-agnostic sequence_name' do
    name = Apartment::Tenant.switch('seq_a') { SequenceWidget.sequence_name }
    expect(name).to eq('sequence_widgets_id_seq')
  end

  it 'draws prefetched ids from the current tenant even when another tenant resolved sequence_name first' do
    # The poisoning step: memoize Model.sequence_name inside seq_a.
    Apartment::Tenant.switch('seq_a') { SequenceWidget.sequence_name }

    drawn = Apartment::Tenant.switch('seq_b') { prefetch_id(SequenceWidget) }

    expect(drawn).to eq(2_001)                      # from seq_b's range
    expect(last_value('seq_a')).to eq(1_000)        # donor untouched
    expect(last_value('seq_b')).to eq(2_001)        # target advanced
  end

  context 'with a pinned model' do
    before do
      # Same-named table in BOTH public and seq_a: the sharp version of the
      # excluded-models guarantee — the pinned model must draw from public
      # even while switched into a tenant that has an identically-named
      # table. (PG schema strategy shares the tenant connection for pinned
      # models and relies on their public.-qualified names; the patch must
      # preserve that qualification.)
      ActiveRecord::Base.connection.create_table(:pinned_settings, force: true) do |t|
        t.string(:key)
      end
      ActiveRecord::Base.connection.select_value(
        %(SELECT setval('public.pinned_settings_id_seq', 500))
      )

      Apartment::Tenant.switch('seq_a') do
        ActiveRecord::Base.connection.create_table(:pinned_settings, force: true) do |t|
          t.string(:key)
        end
        ActiveRecord::Base.connection.select_value(
          %(SELECT setval('"seq_a".pinned_settings_id_seq', 900))
        )
      end

      stub_const('PinnedSetting', Class.new(ActiveRecord::Base) do
        self.table_name = 'pinned_settings'
        include Apartment::Model

        pin_tenant
      end)
      Apartment.adapter.process_pinned_models
    end

    after do
      ActiveRecord::Base.connection.drop_table(:pinned_settings, if_exists: true)
    end

    it 'draws pinned-model ids from the default tenant even inside a tenant switch' do
      drawn = Apartment::Tenant.switch('seq_a') { prefetch_id(PinnedSetting) }

      expect(drawn).to eq(501)                                              # public's range
      expect(last_value('seq_a', sequence: 'pinned_settings_id_seq')).to eq(900) # tenant copy untouched
    end
  end
end
```

- [ ] **Step 1.2: Run it to verify it fails for the right reasons**

Run:

```bash
DATABASE_ENGINE=postgresql bundle exec appraisal rails-8.1-postgresql rspec spec/integration/v4/postgresql_sequence_name_spec.rb
```

Expected: **4 examples, 3 failures** —

- `prepends the patch...` fails with `NameError: uninitialized constant Apartment::Patches::PostgresqlSequenceName`
- `memoizes a schema-agnostic sequence_name` fails with `expected: "sequence_widgets_id_seq", got: "seq_a.sequence_widgets_id_seq"`
- `draws prefetched ids from the current tenant...` fails with `expected 2001, got 1001` (id drawn from `seq_a` — the production bug reproduced)
- `draws pinned-model ids from the default tenant...` **passes** (pinned routing is already correct pre-patch; this example is the guard that the patch doesn't break it)

Do NOT commit yet — the commit lands with the implementation in Task 3 so every branch commit is green.

---

### Task 2: Failing unit spec — stripping semantics (no database)

**Files:**
- Create: `spec/unit/patches/postgresql_sequence_name_spec.rb`

**Interfaces:**
- Produces: the semantic contract for the module's single method: `default_sequence_name(table, column)` — calls `super`, strips the `"#{current_schema}."` prefix when present, preserves everything else, passes `nil` through.

- [ ] **Step 2.1: Write the spec file**

```ruby
# frozen_string_literal: true

require 'spec_helper'

# Pure-logic spec: the module only needs `super` (the Rails-resolved,
# possibly schema-qualified sequence name) and `current_schema` (the
# connection's first resolvable search_path schema), so a fake adapter
# class exercises every branch without a database.
RSpec.describe(Apartment::Patches::PostgresqlSequenceName) do
  let(:adapter_class) do
    Class.new do
      prepend(Apartment::Patches::PostgresqlSequenceName)

      def initialize(resolved:, schema:)
        @resolved = resolved
        @schema = schema
      end

      def default_sequence_name(_table, _column)
        @resolved
      end

      def current_schema
        @schema
      end
    end
  end

  def resolve(resolved:, schema:)
    adapter_class.new(resolved: resolved, schema: schema)
                 .default_sequence_name('widgets', 'id')
  end

  it "strips the connection's own schema prefix" do
    expect(resolve(resolved: 'wssu.widgets_id_seq', schema: 'wssu'))
      .to eq('widgets_id_seq')
  end

  it 'preserves a prefix from another schema (persistent schemas, pinned public. qualification)' do
    expect(resolve(resolved: 'extensions.counters_id_seq', schema: 'wssu'))
      .to eq('extensions.counters_id_seq')
  end

  it 'does not mangle a schema whose name merely starts with the current schema' do
    expect(resolve(resolved: 'wssu_archive.widgets_id_seq', schema: 'wssu'))
      .to eq('wssu_archive.widgets_id_seq')
  end

  it 'passes through an already-unqualified name' do
    expect(resolve(resolved: 'widgets_id_seq', schema: 'wssu'))
      .to eq('widgets_id_seq')
  end

  it 'passes through nil (table has no serial sequence)' do
    expect(resolve(resolved: nil, schema: 'wssu')).to be_nil
  end
end
```

- [ ] **Step 2.2: Run it to verify it fails**

Run: `bundle exec rspec spec/unit/patches/postgresql_sequence_name_spec.rb`

Expected: FAIL with `NameError: uninitialized constant Apartment::Patches::PostgresqlSequenceName` (Zeitwerk has no file to autoload yet). Do NOT commit yet.

---

### Task 3: Implement the patch and register it at gem load

**Files:**
- Create: `lib/apartment/patches/postgresql_sequence_name.rb`
- Modify: `lib/apartment.rb` (bottom of file, just above the Railtie require at the last 3 lines)

**Interfaces:**
- Consumes: Rails `PostgreSQLAdapter#default_sequence_name(table_name, pk)` (via `super`) and `PostgreSQLAdapter#current_schema` (public, `SELECT current_schema`, SCHEMA-class query — runs once per model class per process, at memoization time only).
- Produces: `Apartment::Patches::PostgresqlSequenceName` (Zeitwerk-autoloadable: `lib/apartment/patches/postgresql_sequence_name.rb` → `Apartment::Patches::PostgresqlSequenceName`), prepended onto `ActiveRecord::ConnectionAdapters::PostgreSQLAdapter` whenever/if that adapter loads.

- [ ] **Step 3.1: Create the patch module**

```ruby
# frozen_string_literal: true

module Apartment
  module Patches
    # Keeps ActiveRecord's class-level Model.sequence_name memoization
    # schema-agnostic under pool-per-tenant.
    #
    # Rails resolves default_sequence_name via pg_get_serial_sequence with
    # an unqualified table name, so PostgreSQL answers through the current
    # connection's search_path and returns a schema-QUALIFIED name — the
    # schema of whichever tenant's pool happened to resolve it first.
    # ActiveRecord then memoizes that value once per model class,
    # process-wide. Consumers that render it into SQL (activerecord-import
    # prefetches primary keys as literal nextval(Model.sequence_name))
    # would draw ids from the first-resolver tenant's sequence in every
    # tenant: wrong-tenant ids, silent sequence drift, and eventual
    # PG::UniqueViolation.
    #
    # Stripping the connection's own current_schema prefix makes the
    # memoized value schema-agnostic: nextval('widgets_id_seq')
    # re-resolves through each pool's search_path, per tenant — the same
    # invariant v4 relies on for table names (see
    # docs/designs/v4-connection-model-rationale.md). A prefix naming any
    # OTHER schema is preserved on purpose: persistent-schema tables and
    # pinned models (whose table names are default_tenant-qualified and may
    # execute on a shared tenant connection) are only correct BECAUSE they
    # stay qualified.
    #
    # v3 shipped the same guarantee as PostgreSqlAdapterPatch; it was lost
    # in the Phase 2.5 v3 deletion (PR #356). Reset-on-switch is not an
    # alternative: v4 serves tenants concurrently in one process, so only
    # a schema-agnostic memoized value can be correct.
    module PostgresqlSequenceName
      def default_sequence_name(table_name, pk = 'id')
        res = super
        return res if res.nil?

        prefix = "#{current_schema}."
        res.start_with?(prefix) ? res.delete_prefix(prefix) : res
      end
    end
  end
end
```

- [ ] **Step 3.2: Register the prepend at gem load**

In `lib/apartment.rb`, insert immediately BEFORE the trailing Railtie require (currently the last lines of the file):

```ruby
# Prepend the sequence-name patch whenever the PostgreSQL adapter loads
# (immediately, if it already has). Registered at gem load rather than in
# activate! because ActiveRecord memoizes Model.sequence_name at first
# touch, which can happen during boot before Apartment.activate! runs.
# No-op for apps that never load the PostgreSQL adapter, so MySQL/SQLite
# consumers never pull in pg. See the patch file for the full rationale.
ActiveSupport.on_load(:active_record_postgresqladapter) do
  prepend(Apartment::Patches::PostgresqlSequenceName)
end
```

(`self` inside the block is `ActiveRecord::ConnectionAdapters::PostgreSQLAdapter`; the constant reference triggers Zeitwerk autoload of the new file. `active_support` is already required at the top of `lib/apartment.rb`, which provides `ActiveSupport.on_load`.)

- [ ] **Step 3.3: Run the unit spec — GREEN**

Run: `bundle exec rspec spec/unit/patches/postgresql_sequence_name_spec.rb`
Expected: **5 examples, 0 failures**

- [ ] **Step 3.4: Run the integration spec — GREEN**

Run:

```bash
DATABASE_ENGINE=postgresql bundle exec appraisal rails-8.1-postgresql rspec spec/integration/v4/postgresql_sequence_name_spec.rb
```

Expected: **4 examples, 0 failures**

- [ ] **Step 3.5: Run the full unit suite and full PG integration suite (no collateral damage)**

Run:

```bash
bundle exec rspec spec/unit/
DATABASE_ENGINE=postgresql bundle exec appraisal rails-8.1-postgresql rspec spec/integration/v4/
```

Expected: 0 failures in both.

- [ ] **Step 3.6: Rubocop the new/changed Ruby files**

Run:

```bash
bundle exec rubocop lib/apartment/patches/postgresql_sequence_name.rb lib/apartment.rb \
  spec/unit/patches/postgresql_sequence_name_spec.rb spec/integration/v4/postgresql_sequence_name_spec.rb
```

Expected: no offenses. Fix any style complaints before committing.

- [ ] **Step 3.7: Commit (specs + implementation together — green commit)**

```bash
git add lib/apartment/patches/postgresql_sequence_name.rb lib/apartment.rb \
  spec/unit/patches/postgresql_sequence_name_spec.rb spec/integration/v4/postgresql_sequence_name_spec.rb
git commit -m "Fix(v4): keep Model.sequence_name schema-agnostic under pool-per-tenant

ActiveRecord memoizes Model.sequence_name once per class, process-wide,
resolved schema-qualified via pg_get_serial_sequence on whichever
tenant's connection touches it first. activerecord-import renders the
memoized value into a literal nextval(), so every tenant drew ids from
the first-resolver tenant's sequence: wrong-tenant ids, silent sequence
drift, PG::UniqueViolation on collision.

v3 shipped this guarantee as PostgreSqlAdapterPatch; it was lost in the
Phase 2.5 v3 deletion (#356) with no v4 replacement. Reinstated as
Apartment::Patches::PostgresqlSequenceName: strip the connection's own
current_schema prefix at resolution time (foreign prefixes — persistent
schemas, pinned models' default_tenant qualification — are preserved),
registered via ActiveSupport.on_load(:active_record_postgresqladapter)
at gem load."
```

---

### Task 4: Documentation

**Files:**
- Modify: `lib/apartment/CLAUDE.md` (file-tree entry under `patches/`, currently lines 22-23)
- Modify: `docs/designs/v4-connection-model-rationale.md` (add a caveat bullet under `## Non-goals and honest caveats`, ~line 185)
- Modify: `CLAUDE.md` (repo root — add a Gotchas bullet)

- [ ] **Step 4.1: lib/apartment/CLAUDE.md — extend the patches/ tree entry**

Change:

```markdown
├── patches/               # ActiveRecord patches for tenant-aware connections
│   └── connection_handling.rb # Prepends on AR::Base — tenant-aware connection_pool
```

to:

```markdown
├── patches/               # ActiveRecord patches for tenant-aware connections
│   ├── connection_handling.rb # Prepends on AR::Base — tenant-aware connection_pool
│   └── postgresql_sequence_name.rb # Prepends on PG adapter — schema-agnostic Model.sequence_name memoization
```

(If `live_tenant_propagation.rb` is also listed in that tree, keep the `├──`/`└──` box-drawing consistent — last entry gets `└──`.)

- [ ] **Step 4.2: v4-connection-model-rationale.md — add the caveat bullet**

Append this bullet to the list under `## Non-goals and honest caveats`:

```markdown
- **Class-level ActiveRecord memoization can smuggle a tenant name past the pool
  boundary.** `Model.sequence_name` is memoized once per model class, process-wide, and
  Rails resolves it to a *schema-qualified* name (via `pg_get_serial_sequence`) on
  whichever tenant's connection touches it first. Any consumer that renders that value
  into SQL — `activerecord-import`'s primary-key prefetch does — then draws ids from the
  first-resolver tenant's sequence in every tenant.
  `Apartment::Patches::PostgresqlSequenceName` strips the connection's own schema prefix
  at resolution time so the memoized value stays schema-agnostic and re-resolves through
  each pool's `search_path` — the same invariant this document establishes for tables.
  Prefixes naming other schemas (persistent schemas, pinned models' default-tenant
  qualification) are preserved, because those are correct only *when* qualified.
```

- [ ] **Step 4.3: Root CLAUDE.md — add a Gotchas bullet**

Append under `## Gotchas`:

```markdown
- **`Model.sequence_name` memoization**: Rails memoizes it per model class, process-wide, resolved schema-qualified on whichever tenant's connection touched it first. `Apartment::Patches::PostgresqlSequenceName` (registered at gem load in `lib/apartment.rb`, not in `activate!`) strips the pool's own schema prefix so prefetched ids (e.g. `activerecord-import`) come from the current tenant's sequence. Nothing inside the gem calls `sequence_name` — host-app gems do — so don't remove the patch as "unused".
```

- [ ] **Step 4.4: Commit**

```bash
git add lib/apartment/CLAUDE.md docs/designs/v4-connection-model-rationale.md CLAUDE.md
git commit -m "Docs(v4): document the sequence_name memoization gotcha and its patch"
```

---

### Task 5: Version bump to 4.0.0.alpha8

**Files:**
- Modify: `lib/apartment/version.rb`

- [ ] **Step 5.1: Bump the version**

```ruby
# frozen_string_literal: true

module Apartment
  VERSION = '4.0.0.alpha8'
end
```

- [ ] **Step 5.2: Sanity-check the gem builds**

Run: `gem build ros-apartment.gemspec`
Expected: `Successfully built RubyGem ... ros-apartment-4.0.0.alpha8.gem`. Delete the artifact: `rm -f ros-apartment-4.0.0.alpha8.gem`

- [ ] **Step 5.3: Commit**

```bash
git add lib/apartment/version.rb
git commit -m "Bump version to 4.0.0.alpha8"
```

---

### Task 6: Full verification, push, and PR

**Files:** none (verification + git/gh only)

- [ ] **Step 6.1: Full local matrix pass**

```bash
bundle exec rubocop
bundle exec rspec spec/unit/
bundle exec appraisal rails-8.1-sqlite3 rspec spec/integration/v4/
DATABASE_ENGINE=postgresql bundle exec appraisal rails-8.1-postgresql rspec spec/integration/v4/
```

Expected: 0 offenses, 0 failures everywhere. (MySQL suite is untouched by this change; CI covers it.)

- [ ] **Step 6.2: Push and open the PR against main**

```bash
git push -u origin fix/pg-sequence-name-cross-tenant
gh pr create --base main --title "Fix(v4): keep Model.sequence_name schema-agnostic under pool-per-tenant" --body "$(cat <<'EOF'
## Problem

A consumer on 4.0.0.alpha7 hit `PG::UniqueViolation` on bulk inserts: ids were drawn from **other tenants' sequences**. ActiveRecord memoizes `Model.sequence_name` once per class, process-wide, resolved **schema-qualified** via `pg_get_serial_sequence` on whichever tenant's connection touches it first. `activerecord-import` renders the memoized value into a literal `nextval(...)`, so every tenant drew ids from the first-resolver tenant's sequence — wrong-tenant id ranges, silent sequence drift, and collisions where ranges overlap. Rows still land in the correct schema; only the id source is wrong, which makes the failure mostly silent.

v3 shipped this guarantee as `Apartment::PostgreSqlAdapterPatch#default_sequence_name`; it was deleted in the Phase 2.5 v3 cleanup (#356) with no v4 replacement.

## Fix

`Apartment::Patches::PostgresqlSequenceName`, prepended onto the PG adapter via `ActiveSupport.on_load(:active_record_postgresqladapter)` at gem load: strip the connection's **own** `current_schema` prefix from the resolved name before ActiveRecord memoizes it, so the memoized value is schema-agnostic and `nextval()` re-resolves through each pool's `search_path` per tenant — the same invariant v4 already relies on for table names. Prefixes naming **other** schemas (persistent schemas; pinned models' `default_tenant.` qualification, which may execute on a shared tenant connection) are preserved on purpose.

Reset-on-switch was rejected: v4 serves tenants concurrently in one process, so only a schema-agnostic memoized value can be correct.

## Tests

- Integration (PG): tenant A resolves `sequence_name`, tenant B prefetches → id comes from B's seeded range and A's sequence is untouched (the production bug, reproduced RED pre-patch); memoized name is unqualified; patch is in the adapter's ancestors; pinned model draws from the default tenant even inside a tenant switch with an identically-named tenant-local table.
- Unit: stripping semantics via a fake adapter (own-prefix stripped, foreign prefix preserved, `wssu_archive` vs `wssu` non-mangling, unqualified and nil pass-through).

Includes the version bump to `4.0.0.alpha8` (release PR to `4-0-alpha` follows after merge, per RELEASING.md).
EOF
)"
```

- [ ] **Step 6.3: Watch CI to green**

Run: `gh pr checks --watch`
Expected: all required checks pass (`ci-gate` aggregation job green). Fix anything red before proceeding.

- [ ] **Step 6.4: Squash & merge the PR** (repo convention for `main`). Confirm with the user before merging if they haven't already approved.

---

### Task 7: Release 4.0.0.alpha8 (after the fix PR merges)

**Files:** none (git/gh only) — process per `RELEASING.md` (v4 pre-releases)

- [ ] **Step 7.1: Open the release PR (main → 4-0-alpha)**

```bash
git checkout main && git pull origin main
gh pr create --base 4-0-alpha --head main --title "Release v4.0.0.alpha8"
```

- [ ] **Step 7.2: Merge with a MERGE COMMIT — never squash/rebase this PR**

`4-0-alpha` is a publish gate that tracks `main`; a squash diverges the branches and breaks release notes (see RELEASING.md warning). Merging IS the publish: it triggers `gem-publish.yml`, whose `rake release` step tags `v4.0.0.alpha8` and pushes to RubyGems via trusted publishing. Do not merge until you mean to ship.

- [ ] **Step 7.3: Verify the publish**

```bash
gh run list --workflow gem-publish.yml --limit 1
gem list -r --prerelease ros-apartment
```

Expected: workflow succeeded; `ros-apartment (... 4.0.0.alpha8 ...)` listed.

- [ ] **Step 7.4: Create the GitHub Release** (RELEASING.md step 4)

```bash
gh release create v4.0.0.alpha8 --verify-tag --prerelease --generate-notes
```

---

## Self-Review

- **Spec coverage:** the regression contract (touch tenant A, bulk-prefetch into tenant B, assert B's sequence) is Task 1 example 3; unqualified memoization is example 2; patch ancestry (guards against a repeat of the Phase 2.5 silent deletion) is example 1; the excluded-models/pinned direction the v3 patch handled explicitly is the pinned context. Unit spec pins the pure semantics including the `wssu_archive`-vs-`wssu` prefix edge and nil pass-through. Release covered in Task 7.
- **Consumer rollout invariant** (identical behavior under 3.4.4 and v4, with zero app code): tenant tables memoize the same unqualified value 3.4.4's patch produced; pinned/excluded models stay qualified to the default tenant, same sequence 3.4.4's forced prefix reached.
- **Type consistency:** module name `Apartment::Patches::PostgresqlSequenceName` (Zeitwerk casing, matching the `Postgresql*` adapter renames) is identical in patch file, on_load registration, both specs, and docs. Method signature `default_sequence_name(table_name, pk = 'id')` matches Rails' adapter signature.
- **No placeholders:** every step carries the actual code/command and expected output; the only doc-reference steps point at in-repo files (`RELEASING.md`).
