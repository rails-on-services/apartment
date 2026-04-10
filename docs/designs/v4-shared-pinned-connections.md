# Shared Pinned Model Connections

## Status

Implemented in [#374](https://github.com/rails-on-services/apartment/pull/374)

## Problem

`process_pinned_model` in `AbstractAdapter` unconditionally calls `establish_connection(base_config)`, giving every pinned model its own connection pool. This causes two related bugs:

**FK constraint resolution (PG schema strategy):** The `base_config` passed to `establish_connection` has no explicit `schema_search_path`. PostgreSQL resolves unqualified identifiers via `search_path`, which defaults to `"$user", public` — the session user's schema first, then `public`. If the database user happens to share a name with a tenant schema, or if anything sets `search_path` on the pinned pool's connection, FK constraints that reference unqualified table names resolve against the wrong schema. This affects both DDL-time resolution (migrations, `add_reference`) and DML-time enforcement (inserts that trigger FK checks), though DDL-time is the more common failure mode since FK target OIDs are resolved at constraint creation.

**Wasted pools / broken transactional integrity:** For PG schema strategy and MySQL single-server, the separate pool is unnecessary; the engine supports cross-schema/database queries on a single connection via qualified table names. The separate pool also prevents pinned model writes from participating in the same transaction as tenant model writes. A rollback of tenant DML leaves pinned model rows behind.

Both issues stem from the same code path. The fix addresses both.

## Prior Art

This design incorporates the architectural approach from [rails-on-services/apartment#367](https://github.com/rails-on-services/apartment/pull/367) by [@henkesn](https://github.com/henkesn), which identified the problem and proposed the `shared_connection_supported?` / `qualify_pinned_table_name` pattern. This design rewrites the implementation against the current `main` branch, adds a config opt-out (`force_separate_pinned_pool`), fixes the FK constraint resolution bug for the separate-pool path, and incorporates review feedback from that PR.

## Design

### Template Methods on AbstractAdapter

Two new methods on `AbstractAdapter`:

**`shared_pinned_connection?`** — single decision point combining engine capability and config override. Returns `false` by default (safe fallback). PG schema adapter and MySQL adapters override to return `true` unless `Apartment.config.force_separate_pinned_pool` is set. Consumers (`process_pinned_model`, `ConnectionHandling`) call this one method; no scattered `&&` checks.

**`qualify_pinned_table_name(klass)`** — abstract; required when `shared_pinned_connection?` returns `true`. Qualifies the model's table name so it targets the default tenant's tables from any tenant connection. Raises `NotImplementedError` on the base class as a guard. Subclasses provide the qualifier string (schema name for PG, database name for MySQL).

#### Table Name Qualification Strategy (Hybrid)

Qualification uses a hybrid approach that respects Rails' `table_name_prefix` / `table_name_suffix` machinery where possible, falling back to direct assignment for models with explicit `self.table_name`:

```ruby
def qualify_pinned_table_name(klass)
  if explicit_table_name?(klass)
    # Model has explicit self.table_name = 'custom' — qualify directly.
    # Strips at most one leading segment (schema or database prefix).
    table = klass.table_name.sub(/\A[^.]+\./, '')
    klass.table_name = "#{qualifier}.#{table}"
  else
    # Convention naming — set table_name_prefix, let Rails compose via
    # compute_table_name. Preserves nested-class `contained` segments
    # and table_name_suffix. reset_table_name recomputes @table_name.
    klass.table_name_prefix = "#{qualifier}."
    klass.reset_table_name
  end
end
```

Each adapter subclass implements this with its own `qualifier`: `default_tenant` for PG schema (e.g. `"public"`), `base_config['database']` for MySQL (e.g. `"myapp_production"`). Note: `base_config` already returns string keys (via `connection_config.transform_keys(&:to_s)`), so `base_config['database']` is safe regardless of whether the original config used symbol keys.

**Detecting explicit table names:** `@table_name` is set both by `self.table_name = 'custom'` (explicit) and by the first call to `table_name` (lazy convention computation). To distinguish these, `process_pinned_model` must run before any `table_name` access on the class. This is guaranteed by the boot order: `Tenant.init` (called from `config.after_initialize` in the Railtie) processes all registered pinned models before the app serves requests. For models autoloaded after boot (Zeitwerk), `pin_tenant` calls `process_pinned_model` immediately — before any query triggers `table_name`. The `explicit_table_name?` helper checks `klass.instance_variable_defined?(:@table_name)` *and* compares the cached value against what `compute_table_name` would produce. If they differ, the model has an explicit assignment:

```ruby
def explicit_table_name?(klass)
  return false unless klass.instance_variable_defined?(:@table_name)

  # Compare cached @table_name against what convention naming would produce.
  # If they differ, the model has an explicit self.table_name = assignment.
  cached = klass.instance_variable_get(:@table_name)
  computed = klass.send(:compute_table_name)
  cached != computed
end
```

This is more robust than checking `@table_name` alone, which can be set by lazy convention computation. The `compute_table_name` call is cheap (string assembly, no IO).

**Edge case:** If a model sets `self.table_name` to the exact string convention would compute (e.g., `self.table_name = 'delayed_jobs'` on a class named `DelayedJob`), `cached == computed` and the convention path runs. The result is still a correctly qualified name; the only difference is mechanism (prefix + reset vs direct assignment). This is acceptable — the convention path is the superset.

**Why hybrid:** Rails' `table_name_prefix` is a `class_attribute` that feeds into `compute_table_name` (`full_table_name_prefix + contained + undecorated_table_name + full_table_name_suffix`). Using it means pinned models with `table_name_suffix`, nested-class naming, or module-level prefixes get composed correctly by Rails' own assembly. But `reset_table_name` overwrites `@table_name`, which destroys explicit `self.table_name = 'custom'` assignments. The `explicit_table_name?` check detects this case and falls back to direct assignment.

**Explicit-path prefix stripping:** Uses `sub(/\A[^.]+\./, '')` instead of `split('.').last`, stripping at most one leading `schema.` or `database.` segment. This preserves names that contain dots for other reasons (unlikely in practice, but defensive).

**STI:** Subclasses use `base_class.table_name`. Once the base class is qualified, STI children inherit the qualified name automatically. `table_name_prefix` is a `class_attribute` that also inherits to subclasses, so the convention path works for STI without extra handling. `apartment_pinned?` already walks the superclass chain (model.rb:28-30), so STI children are recognized as pinned without their own `pin_tenant` call.

**`class_attribute` inheritance:** Setting `table_name_prefix` on a pinned class propagates to subclasses. This is correct for STI, where all subclasses share the same physical table. Only STI subclasses of pinned bases are supported; don't subclass a pinned model with a tenant-scoped model that needs its own table — use composition instead.

**Limitation:** Qualification only affects AR-generated SQL via `table_name`. Raw SQL (`execute`, `find_by_sql`), Arel fragments that hardcode unqualified table names, and `FROM` clauses in custom scopes are not covered. This is the same limitation as v3's `excluded_models` and is documented rather than solved.

### Adapter Matrix

| Adapter | `shared_pinned_connection?` | Table qualification | Rationale |
|---|---|---|---|
| PostgresqlSchemaAdapter | `true` | `"#{default_tenant}.#{table}"` | Schemas share a catalog |
| Mysql2Adapter | `true` | `"#{base_config['database']}.#{table}"` | MySQL supports `db.table` on same server |
| TrilogyAdapter | `true` (inherited) | Inherited from Mysql2Adapter | Same engine, different driver |
| PostgresqlDatabaseAdapter | `false` (inherited) | N/A — separate pool | PG databases are fully isolated |
| Sqlite3Adapter | `false` (inherited) | N/A — separate pool | Separate files |

PG schema example: when `default_tenant` is `'public'`, qualification produces `"public.delayed_jobs"`. MySQL example: when `base_config['database']` is `'myapp_production'`, qualification produces `"myapp_production.delayed_jobs"`. The qualifier is always derived from runtime config, never hardcoded.

**Do not apply `environmentify` to qualifiers.** `environmentify` maps tenant keys to tenant database names (e.g., `acme` → `test_acme`); it does not apply to the default connection's database/schema identifiers. `default_tenant` (PG) and `base_config['database']` (MySQL) are already the real server-side names. Environmentifying them would produce wrong names under `:prepend`/`:append` strategies.

When `force_separate_pinned_pool: true`, all adapters behave as separate-pool regardless of engine capability.

### Modified process_pinned_model

Dual-path logic:

```ruby
def process_pinned_model(klass)
  return if klass.instance_variable_get(:@apartment_pinned_processed)

  if shared_pinned_connection?
    qualify_pinned_table_name(klass)
  else
    klass.establish_connection(pinned_model_config)
  end

  klass.instance_variable_set(:@apartment_pinned_processed, true)
end
```

The ivar is renamed from `@apartment_connection_established` to `@apartment_pinned_processed`; it mirrors `process_pinned_model` and is mechanism-neutral (suggested by @henkesn).

**Ivar rename touchpoints** (all known references to `@apartment_connection_established`):
1. `lib/apartment/adapters/abstract_adapter.rb` — `process_pinned_model` (get and set)
2. `lib/apartment.rb:124-127` — `clear_config` teardown (checks `defined?` then `remove_instance_variable`)
3. `spec/unit/adapters/abstract_adapter_spec.rb` — idempotency test comment

Implementation must also run `rg apartment_connection_established` to catch any references in docs/plans that should be updated for consistency. Additionally, `clear_config` must clean up the new ivars (`@apartment_original_table_name`, `@apartment_qualification_path`) alongside `@apartment_pinned_processed`.

**Teardown in `clear_config`:** Beyond renaming the ivar, `clear_config` must restore pinned models to their pre-qualification state. The approach depends on which qualification path was used:

- **Convention path:** Reset `klass.table_name_prefix = ""` and call `klass.reset_table_name`. This recomputes the unqualified name from Rails' convention machinery.
- **Explicit path:** The original `self.table_name` value was overwritten by direct assignment. To restore it, `process_pinned_model` stores the pre-qualification name in `@apartment_original_table_name` before qualifying. Teardown restores it via `klass.table_name = klass.instance_variable_get(:@apartment_original_table_name)`.

`process_pinned_model` also sets `@apartment_qualification_path` (`:convention` or `:explicit`) so teardown knows which branch to take. Both ivars are cleaned up alongside `@apartment_pinned_processed`.

`clear_config` is primarily used in test suites (reconfigure between examples) and full app reload (Zeitwerk). In production, Apartment is configured once at boot; teardown is not expected.

Note: the existing shared path for schema strategy (`table_name = "#{default_tenant}.#{table}"` after `establish_connection`) is replaced — not duplicated — by the new `qualify_pinned_table_name` call. The shared path qualifies *without* `establish_connection`; the separate path calls `establish_connection` *without* qualifying (since the pinned pool's `schema_search_path` handles resolution).

### pinned_model_config (Separate-Pool Path)

New private method on `AbstractAdapter`, adjacent to `base_config`. For the separate-pool path, it builds on `base_config`:

- For schema strategy: merges `schema_search_path` set to `default_tenant` plus `persistent_schemas` (quoted). This fixes FK constraint resolution; without it, the connection inherits PG's default search path and FK references may resolve against the wrong schema.
- For database strategies: returns `base_config` unchanged; the raw config already points to the real default database.

This ensures apps that set `force_separate_pinned_pool: true` on PG schema strategy still get correct FK behavior.

### Modified ConnectionHandling#connection_pool

The existing early return for pinned models:

```ruby
return super if self != ActiveRecord::Base && Apartment.pinned_model?(self)
```

Becomes conditional on the adapter requiring a separate pool:

```ruby
if self != ActiveRecord::Base && Apartment.pinned_model?(self) &&
   !Apartment.adapter&.shared_pinned_connection?
  return super
end
```

When shared connections are supported, pinned models fall through to the tenant pool lookup, so they share the tenant's connection and participate in its transactions.

**Schema cache interaction:** When `schema_cache_per_tenant` is enabled, `ConnectionHandling` loads a per-tenant cache into the pool. If pinned models share the tenant pool, they share that cache instance. This is correct: the qualified table name (`public.delayed_jobs`) resolves through PG/MySQL's normal catalog lookup regardless of which schema cache is loaded. The schema cache stores metadata by table name; the pinned model's qualified name won't collide with unqualified tenant table names. No special handling needed, but integration tests should verify pinned model column lookups work with `schema_cache_per_tenant: true`.

### Config

New boolean on `Apartment::Config`:

- `force_separate_pinned_pool` — default `false`
- Validated in `validate!`: must be `true` or `false`
- Top-level (strategy-agnostic); applies to all adapters
- Escape hatch for: multi-server MySQL topologies, apps that rely on pinned model writes surviving tenant transaction rollbacks

No other config changes.

### Upgrade Guide

`docs/upgrading-to-v4.md` gets a new section covering:

- What changed: pinned models on PG schema / MySQL single-server now share the tenant's connection pool via qualified table names
- Adapter matrix showing which strategies are affected
- Migration action: if code relies on pinned model writes surviving tenant rollbacks (e.g., enqueue-then-rollback), set `force_separate_pinned_pool: true`
- `after_commit` callbacks still fire as before; the difference is that pinned model writes are now *inside* the tenant transaction, so an `ActiveRecord::Rollback` that aborts the transaction will also roll back pinned model writes. Apps using `after_commit` for job enqueueing are unaffected (the callback fires after successful commit in both old and new behavior).

### connects_to Interaction

Models (or abstract base classes) that use `connects_to` to point at a *different physical database* than the tenant pool must use `pin_tenant` with `force_separate_pinned_pool: true`, or they will be routed through the tenant pool where their tables don't exist. This is already documented in CLAUDE.md as a gotcha. The shared pinned connection path assumes the pinned model's tables are reachable from the tenant's connection; `connects_to` to a separate database breaks that assumption.

## Testing

### Unit Tests

- `AbstractAdapter#shared_pinned_connection?` returns `false` by default
- `AbstractAdapter#process_pinned_model`: both code paths (shared vs separate), idempotency via `@apartment_pinned_processed`
- Each concrete adapter: `shared_pinned_connection?` return value, `qualify_pinned_table_name` output (including already-qualified and custom table names)
- `qualify_pinned_table_name` hybrid paths: convention-named model uses `table_name_prefix` + `reset_table_name`; explicit `self.table_name` model uses direct assignment
- `qualify_pinned_table_name` with `table_name_suffix` set (convention path preserves it)
- `explicit_table_name?` helper: returns `true` when cached differs from computed, `false` when equal (convention path), `false` when `@table_name` not yet set
- `ConnectionHandling#connection_pool`: pinned model routing for both shared and separate paths
- `Config#force_separate_pinned_pool` validation and default

### Integration Tests

- Pinned model queries target default tenant data during tenant switch
- Transactional integrity: rollback rolls back both pinned and tenant writes (shared path)
- Transactional isolation: rollback only rolls back tenant writes (`force_separate_pinned_pool: true`)
- FK constraint resolution on PG schema strategy (both paths)
- Idempotency of `process_pinned_models`
- Association join between tenant model and pinned model (e.g., `TenantModel.joins(:pinned_model)`) produces correct SQL with qualified table name
- Schema cache interaction: pinned model column lookups with `schema_cache_per_tenant: true`

Test cases are reimplemented from PR #367, adapted to the current test infrastructure. Each behavior (shared vs separate) gets its own `context` block; no `if/else` within a single example.

## Attribution

Commits deriving from PR #367's design will include `Co-Authored-By: henkesn <14108170+henkesn@users.noreply.github.com>`. The PR description will reference and acknowledge the original contribution.

## Out of Scope

- Performance instrumentation on the `connection_pool` hot path (noted for future work; v4 should not regress vs v3)
- Automatic multi-server MySQL detection (config opt-out is sufficient)
- `shard` / `database_config` strategy support for shared connections
- Shared pinned connections for models using `connects_to` with a different physical database (these must remain separate-pool)
