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

**`pinned_table_qualifier`** — abstract; required when `shared_pinned_connection?` returns `true`. Returns the namespace that reaches the default tenant's tables from any tenant connection: `default_tenant` for PG schema (e.g. `"public"`), `base_config['database']` for MySQL (e.g. `"myapp_production"`). Raises `NotImplementedError` on the base class as a guard. Note: `base_config` already returns string keys (via `connection_config.transform_keys(&:to_s)`), so `base_config['database']` is safe regardless of whether the original config used symbol keys.

**`qualify_pinned_table_name(klass)`** — concrete on `AbstractAdapter`; qualifies the model's table name using that qualifier. Subclasses supply only the qualifier.

#### Table Name Qualification Strategy (Direct Assignment)

Qualification always assigns `table_name` directly:

```ruby
def qualify_pinned_table_name(klass)
  # Captured before the assignment, which would otherwise make every
  # model look explicitly named.
  path = klass.apartment_explicit_table_name? ? :explicit : :computed
  original = klass.table_name
  klass.table_name = "#{pinned_table_qualifier}.#{original.sub(/\A[^.]+\./, '')}"
  klass.apartment_mark_processed!(path, (original if path == :explicit))
end
```

Reading `klass.table_name` first lets Rails compute the conventional name — honouring any `table_name_prefix`, `table_name_suffix`, or nested-class `contained` segment the app declared — and we qualify the finished string.

**Prefix stripping:** Uses `sub(/\A[^.]+\./, '')` instead of `split('.').last`, stripping at most one leading `schema.` or `database.` segment. This preserves names that contain dots for other reasons (unlikely in practice, but defensive) and makes re-qualification idempotent.

#### Qualification proves its own outcome

Every silent cross-tenant read this gem has shipped had one signature: qualification ran, produced an unqualified name, marked the model processed, and raised nothing. The model then served the tenant's rows indefinitely. `verify_pinned_qualification!` closes that class of bug by checking the post-condition — the table name actually carries the qualifier — and raising `ConfigurationError` when it does not. A boot failure instead of wrong data.

It also guards the private-API risk: `compute_table_name` is not public Rails, and a future change to the naming internals that silently stopped composing the way this design expects would surface as a boot error on the first affected app rather than as cross-tenant reads.

Three scoping decisions, each load-bearing:

- **The no-op branch is not verified.** A subclass sharing an already-pinned base's table is correct by construction, and if its base has not been qualified yet — registry order puts children first when a child is pinned before its parent — asserting on it would fail a boot for a model about to become correct.
- **Descendants that declare their own table are excluded.** An ancestor's qualification was never meant to reach them, and `warn_unregistered_pinned_subclasses` already reports that shape. Raising there would break the tenant-scoped subclass the gem deliberately tolerates.
- **The descendant set is computed independently of the resync set.** The resync pass is deliberately limited to descendants holding a memo, because only those need resetting. Verification cannot inherit that limit: a descendant with no memo computes its name lazily and can be just as wrong. An early version reused the resync set and missed exactly that case — the engine-namespaced descendant, which is the shape most likely to hit it.

An abstract base has no table of its own, so it is proven through the descendants its prefix was meant to reach.

**Upgrade consequence.** The engine-namespaced descendant limitation below now raises at boot rather than silently reading the tenant's tables. That is the intended trade, and it means an app with that topology stops booting until it pins the descendant explicitly.

#### Descendant table-name memos must be resynced

Rails memoizes `@table_name` per class on first read and **never invalidates a descendant's copy** when an ancestor's name or prefix changes. Qualification mutates one class; every descendant that already read its own `table_name` keeps the pre-qualification value.

That is not hypothetical. Anything touching a descendant's `table_name` before `Tenant.init` — an initializer, an eager-loading gem, a route constraint, a `descendants` sweep — freezes the unqualified name, and the "pinned" model then resolves to the **tenant's** table for the life of the process. It also produced a *false* warning: the stale memo no longer matches `compute_table_name`, so `apartment_explicit_table_name?` read `true` and `warn_unregistered_pinned_subclasses` reported that the model "declares its own table", which it does not.

So `qualify_pinned_table_name` and `apartment_restore!` both bracket their mutation:

1. `apartment_descendants_inheriting_table_name` — **before** mutating, collect descendants that have memoized a name they did not declare. The ordering is load-bearing: afterwards there is no way to distinguish a stale memo from a genuine declaration, because the ancestor's change has moved what convention computes.
2. `apartment_resync_descendant_table_names!` — after mutating, `reset_table_name` each of them. That routes through Rails' own `table_name=` setter, so the derived `@quoted_table_name` and `@arel_table` caches are cleared with it.

Descendants with no memo are deliberately omitted — they compute lazily and pick the new value up unaided.

**What counts as "inherited" is `apartment_inherited_table_name`, not `compute_table_name`.** The two disagree for a class whose superclass is abstract: `reset_table_name` prefers `superclass.table_name`, while `compute_table_name` treats such a class as its own `base_class` and builds from its own `model_name`. A concrete class under an abstract intermediate that carries a table — an abstract class sandwiched beneath a concrete pinned parent — therefore *inherits* `foos` but *computes* `gkids`. Keying on `compute_table_name` misread that inherited name as an explicit declaration, skipped the resync, and left the model reading the tenant's table. The predicate mirrors `reset_table_name`'s own branching instead.

The collected set is sorted by ancestor depth so an intermediate is always reset before anything beneath it. `reset_table_name` on a class under an abstract parent reads `superclass.table_name` — the memo, not `base_class` — so a grandchild reset first would re-freeze its parent's stale value. ActiveSupport's `descendants` happens to return ancestors first today, but that ordering is undocumented; the sort makes the pass order-independent.

**A descendant whose declared table differs from convention is left alone** — it is unaffected by an ancestor's qualification, and qualifying it is a separate decision requiring its own `pin_tenant`. A declaration that happens to *equal* what convention computes is indistinguishable from an inherited name (Rails retains no "explicitly set" flag), so it is treated as inherited and qualified along with the ancestor. That is the safe side of an unavoidable ambiguity: such a class descends from a pinned base, so it is a pinned model, and qualifying it targets the default tenant — whereas leaving it alone would resolve through `search_path` to the tenant's table. The cost is that this shape no longer trips `warn_unregistered_pinned_subclasses`, so a model intended as tenant-scoped is silently qualified rather than flagged; declaring a table that differs from convention, or pinning explicitly, keeps the signal.

Both helpers rescue per descendant: Rails' naming machinery raises on shapes the gem does not control (an anonymous class has no `model_name`), and neither qualification nor teardown may fail on one bad descendant.

**Abstract classes qualify by broadcast, not assignment.** An abstract class has no table of its own — `table_name` is `nil` — so there is nothing to assign, and interpolating it would raise. Pinning one is a supported pattern (an abstract `connects_to` base is pinned so Apartment does not build tenant pools for it; see the `connects_to` gotcha in the root `CLAUDE.md`).

Its qualifier still has to reach the concrete descendants that inherit the pin, and those are **never qualified directly**: `pin_tenant` early-returns once any superclass is pinned (`apartment_pinned?` walks the chain), so a descendant is never registered and `process_pinned_models` never sees it. `qualify_pinned_table_name_prefix` therefore sets `table_name_prefix` — a `class_attribute`, so it broadcasts down the inheritance chain and each descendant composes it in its own `compute_table_name`. Any prefix the app set is preserved rather than overwritten (`myapp_` becomes `<qualifier>.myapp_`). Teardown restores the original prefix (`:prefix` path).

This is the one place the prefix mechanism remains correct, and the distinction is the whole point: here it is a **broadcast to other classes**, not an attempt to qualify the class's own name. Removing it wholesale regressed exactly the silent-tenant-read this design exists to prevent — a pinned `GlobalRecord` abstract base left `GlobalSetting` resolving to `global_settings` instead of `public.global_settings`.

#### Subclasses of a concrete pinned model

A subclass can mean two opposite things, and the gem originally could not tell them apart — both inherit `apartment_pinned? == true` through the superclass walk, and neither was registered, because `pin_tenant` early-returned once *any* superclass was pinned:

| Shape | Intent | Behaviour before |
|---|---|---|
| **A** STI child sharing the parent's table | global | correct — resolves through `base_class.table_name` |
| **B** own table, calls `pin_tenant` | global | **`pin_tenant` silently no-opped**; unqualified |
| **C** own table, never pinned | tenant-scoped | unqualified |

Measured, the defect **inverts by adapter path**, so no configuration was correct for both:

| | B (wants global) | C (wants tenant) |
|---|---|---|
| Shared connection (PG schema, MySQL) | reads tenant ❌ | reads tenant ✅ |
| Separate pool (`force_separate_pinned_pool`, PG database-per-tenant, SQLite) | reads default ✅ | reads default ❌ |

**Resolution.** `pin_tenant` is now idempotent *per class* rather than per hierarchy, so B registers and qualifies when declared. A is skipped at qualification time by `inherits_pinned_table?` — a subclass with no table of its own reaches its table through `base_class.table_name`, which the base's qualification already covers; assigning would freeze a copy onto the child and desynchronise the two on teardown. C is untouched.

The justification does **not** rest on B being a good idea. B is an anti-pattern whose one real appearance is transitional — migrating an STI child off a pinned parent's table — and the correct steady-state shapes are a pinned abstract base or a shared concern. But an API call that is accepted and silently does nothing is wrong regardless: it must either work or be absent.

`inherits_pinned_table?` is a discriminator, and discriminators in this method have a poor record (see above). It differs in kind: it asks whether the base class is **in the pin registry**, a fact the gem owns, rather than inferring intent from Rails' naming internals.

**Residual gap, warned not raised.** A subclass in shape C — or in shape B without the `pin_tenant` call — is still unqualified. `warn_unregistered_pinned_subclasses` walks `descendants` after processing and warns. Detection is complete under eager loading (production boot, CI) and partial under Zeitwerk lazy loading, which is tolerable for a warning and would not be for a raise. The transitional window is exactly when this bites, and a silent failure there reads as a botched backfill.

**Why not `table_name_prefix` (superseded hybrid):** The original design set `table_name_prefix = "#{qualifier}."` and called `reset_table_name` for convention-named models, falling back to direct assignment only for explicit `self.table_name`. That was unsound. `compute_table_name` consults `full_table_name_prefix` **only on its `base_class?` branch**; every other route ignores the prefix, and Rails raises nothing when it does. Three shipped failure modes, all silent — the model kept resolving through `search_path` to the *tenant's* table:

| Model shape | Produced | Should have been |
|---|---|---|
| Not its own `base_class` (`compute_table_name` returns `base_class.table_name` verbatim) | `versions` | `public.versions` |
| Module parent defines `table_name_prefix` (`full_table_name_prefix` prefers the parent's) | `billing_invoices` | `public.billing_invoices` |
| Model sets its own `table_name_prefix` (overwritten, so the app's prefix is dropped) | `public.ledgers` | `public.myapp_ledgers` |

The third is worse than a no-op: it points the model at a *different* table rather than an unqualified one.

The trigger for the first row is worth stating precisely, because the original design called it a benign edge case ("the convention path is the superset"): `apartment_explicit_table_name?` compares `@table_name` against `compute_table_name`, and for a subclass `compute_table_name` *is* `base_class.table_name`. So the very common `self.table_name = 'versions'` on a subclass of a model whose table is `versions` reads as "identical to convention" and routes into the path that cannot qualify it. The predicate was answering a restore question and being used to answer a qualification question — see below.

**Detecting explicit table names (restore only):** `@table_name` is set both by `self.table_name = 'custom'` (explicit) and by the first call to `table_name` (lazy convention computation), so `apartment_explicit_table_name?` compares the cached value against `compute_table_name` rather than merely checking that the ivar exists. It is now used solely to choose a **restore** strategy, where the comparison is exactly the right question: if convention reproduces the current name, qualification can be undone by discarding the override and recomputing (`:computed`); if it does not, the name must be saved and restored verbatim (`:explicit`). The `compute_table_name` call is cheap (string assembly, no IO), and it remains a private Rails API covered by the Rails-main canary in CI.

This also removes the ordering constraint the hybrid carried: qualification no longer depends on `process_pinned_model` running before any `table_name` access, because a memoized conventional name is exactly what we want to read.

**STI:** `apartment_pinned?` walks the superclass chain (model.rb:28-30), so STI children are recognized as pinned without their own `pin_tenant` call. A child that is itself pinned is now qualified on its own merits rather than depending on its base class having been pinned and qualified first — which is what the first failure mode above amounted to. Because qualification no longer touches `table_name_prefix`, it no longer leaks to subclasses through `class_attribute` inheritance.

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

- **`:computed` path:** The pre-qualification name was reproducible by Rails' convention machinery, so teardown discards the override — `remove_instance_variable(:@table_name)` followed by `reset_table_name`. Dropping the ivar rather than assigning the old string back leaves the model responsive to later `table_name_prefix` and base-class changes, exactly as it was before pinning.
- **`:explicit` path:** The original `self.table_name` value cannot be rebuilt by convention, so `qualify_pinned_table_name` stores it in `@apartment_original_table_name` before qualifying, and teardown assigns it back verbatim.

`qualify_pinned_table_name` sets `@apartment_qualification_path` (`:computed` or `:explicit`) so teardown knows which branch to take. Both ivars are cleaned up alongside `@apartment_pinned_processed`. Teardown never touches `table_name_prefix`, because qualification never sets it.

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
- `qualify_pinned_table_name` produces a qualified `table_name` for every model shape — convention-named, explicit `self.table_name`, already-qualified (idempotent), non-`base_class?` subclass, module-parent `table_name_prefix`, and own `table_name_prefix`. Asserted on the resulting `table_name`, never on the mutators used to reach it: mocking `table_name_prefix=` / `reset_table_name` is what hid the three failure modes above.
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
