# v4 Schema-Cache Recovery (Failure-Class Member 8)

Status: design. Addresses fixture-pool-lifecycle failure-class **member 8** (schema-cache / prepared-statement drift after tenant DDL) for the v4 beta gate. Bundles a manual recovery helper with a fix for the currently-broken `schema_cache_per_tenant` load path discovered during this design.

## TLDR

**Member 8 is largely mitigated by v4's architecture, not a v3-style cross-tenant bug.** Pool-per-tenant gives each tenant its own `pool.schema_cache`, so one tenant's DDL cannot corrupt another's cache through a shared connection. ActiveRecord self-heals prepared statements on PostgreSQL (the `0A000` → `PreparedStatementCacheExpired` retry). The residual is narrow: a long-lived process holding a **stale schema cache** after DDL it didn't run — same as vanilla Rails warm-worker-after-migration, cured by deploy restart — plus one apartment-specific amplifier: DDL on a **pinned/shared (public-schema) table** that N warm tenant pools have cached → N stale caches at once. We ship a small **manual, current-process** recovery helper (`Apartment::Tenant.reload_schema_cache!`) for that amplifier and console/recovery use, document the cross-process limit as deploy-restart territory, and fix a latent bug found en route (the `schema_cache_per_tenant` load path calls a removed ActiveRecord API).

## Verdict layer

- **Helper — `Apartment::Tenant.reload_schema_cache!(tenant = nil)`**: clears the schema cache across all warm tenant pools **and the default pool**, lazy-repopulating from the DB. Manual, current-process only. See [The helper](#the-helper).
- **Schema-cache only, not prepared statements**: AR self-heals prepared statements on PG; pool-wide statement clearing is partial under concurrency and over-promises. See [What it does not do](#what-it-does-not-do).
- **Bundled bug fix — `schema_cache_per_tenant` load path**: `connection_handling.rb` calls `pool.schema_cache.load!(cache_path)`, but that method takes no arguments in Rails 7.2/8.0/8.1 → `ArgumentError`. Fix uses the stable `pool.schema_reflection = SchemaReflection.new(path)` API. See [Bundled fix](#bundled-fix-schema_cache_per_tenant-load-path).
- **Manual-only for beta**: a migrator auto-hook buys nothing on a separate-migration-server topology; noted as a possible GA follow-up. See [Manual-only](#manual-only-no-migrator-auto-hook).
- **Documented limits**: cross-process staleness (other workers) and model-level `@columns_hash` staleness are out of the helper's reach. See [What it does not do](#what-it-does-not-do).

## Why member 8 is narrow in v4

| v3 framing (member 8 "suspected") | v4 reality | Residual |
|---|---|---|
| Tenant A's DDL drifts tenant B's cache via shared connection / search_path | Each tenant has its own pool + own `schema_cache`; no shared mutable cache | None cross-tenant |
| Prepared-statement plan mismatch after DDL | AR maps PG `0A000` → `PreparedStatementCacheExpired`, deletes the statement and retries outside a transaction | In-transaction + non-PG: vanilla-Rails limit, not ours |
| Stale column metadata after migration | Warm pool holds old `schema_cache` until reload | Same as vanilla Rails; deploy restart cures it |
| — | Pinned/shared-table DDL hits N warm tenant pools at once | **The one apartment-specific amplifier** the helper targets |

The amplifier is amplification in **count, not kind**: all N stale caches heal identically (restart, or this helper). With backward-compatible (additive) migration discipline, none of the N actually bite — old code doesn't reference the new schema. The helper is cheap insurance for the cases that escape that discipline (console DDL, non-additive changes, tests).

## The helper

```ruby
Apartment::Tenant.reload_schema_cache!(tenant = nil)
```

- **Default (`tenant` nil)**: clears `pool.schema_cache` on every warm tenant pool tracked by `PoolManager`, **plus `ActiveRecord::Base.connection_pool`** (the default pool, which `PoolManager` does not track — the default tenant short-circuits before pool registration, and separate-pool pinned models live there too).
- **Scoped (`tenant` given)**: clears only that tenant's warm pool(s) (prefix match on the `"#{tenant}:#{role}"` key convention), still including the default pool when the named tenant is the default.
- **Mechanism**: `BoundSchemaReflection#clear!` resets the underlying reflection's `@cache` to an empty cache. The next reflection access lazily repopulates **from the database** (verified: `cache(pool)` is `@cache ||= load_cache(pool) || empty_cache`; after `clear!`, `@cache` is the non-nil empty cache, so the dump file is *not* re-read — DB is queried). This is why no YAML-file deletion is needed even under `schema_cache_per_tenant: true`.
- **Naming**: `reload_schema_cache!` is chosen for ergonomics; the reload is lazy (clear now, repopulate on next access). Documented as such.

### Concurrency contract

`clear!` is a single assignment to a fresh empty cache — memory-safe, but **not a linearized invalidation barrier**. An in-flight request may finish against metadata it already read. This is the same contract ActiveRecord's own post-migrate `schema_cache.clear!` carries (`DatabaseTasks` clears the migration pool's cache assuming no concurrent traffic). The helper is documented for **console / post-migrate / low-traffic maintenance**, not the mid-request hot path.

## What it does not do

- **Cross-process**: cannot reach other workers' pools (web/Sidekiq). Fleet-wide DDL still requires a rolling restart; this is documented, not engineered around. Proactive cross-process invalidation remains the deferred opt-in transport seam.
- **Prepared statements**: not cleared. PG self-heals outside transactions; inside a transaction AR raises `PreparedStatementCacheExpired` and the transaction aborts (a vanilla-Rails limit). Pool-wide statement clearing would only reach connections the caller holds, not ones checked out by other threads — it over-promises, so we omit it. MySQL/Trilogy lack the PG self-heal path; those adopters lean harder on restart (documented).
- **Model column caches**: `pool.schema_cache.clear!` does **not** reset model `@columns_hash` (`Model.reset_column_information` is independent). A model that already loaded its columns keeps them until `reset_column_information` or restart. The helper clears the *pool* cache and documents that model-level attribute staleness needs a model reset or restart. It does not reset models generically — it cannot reliably map models to tenants.

## Manual-only (no migrator auto-hook)

Migrations run on a server separate from app and Sidekiq, so the migrator process runs DDL and exits; the stale warm pools live in other processes it cannot reach. An in-process auto-hook would clear only the migrator's own cache moments before exit — zero value. Manual-only is correct for this topology. A **conditional auto-hook** (fire only when the migrating process already holds warm pools — `rails runner`, embedded migration jobs) is a possible GA follow-up, explicitly out of beta scope.

## Bundled fix: `schema_cache_per_tenant` load path

Found during this design. `lib/apartment/patches/connection_handling.rb` (`load_tenant_schema_cache`) calls:

```ruby
pool.schema_cache.load!(cache_path)   # BROKEN
```

`pool.schema_cache` returns a `BoundSchemaReflection`, whose `load!` takes **no arguments** in Rails 7.2/8.0/8.1 (`def load!; @schema_reflection.load!(@pool); end`). Passing `cache_path` raises `ArgumentError`. The path-taking `load!` was a pre-7.1 API. The feature is latent-broken: the config defaults to `false`, and the `true` path has no real-file round-trip test.

Fix uses the stable Rails 7.1+ API:

```ruby
pool.schema_reflection =
  ActiveRecord::ConnectionAdapters::SchemaReflection.new(cache_path)   # FIXED
```

`SchemaReflection.new(cache_path)` binds the reflection to the dump file and lazily loads it; `ConnectionPool#schema_reflection=` swaps it in and resets the bound cache. Rails additionally version-checks the dump on load and ignores a stale file with a warning, so the repaired feature is self-protecting against an out-of-date dump. Bundled here because it is the same subsystem and the same file as the helper; it ships with its own round-trip test (dump a tenant's cache, establish the pool with `schema_cache_per_tenant: true`, assert the cache is populated from the file without a DB hit).

## Components & files

- `lib/apartment/tenant.rb` — add `reload_schema_cache!(tenant = nil)` to the public API facade.
- `lib/apartment/pool_manager.rb` — a small read accessor if needed to enumerate warm pools for clearing (reuse `each_pair` / existing key conventions; no new state).
- `lib/apartment/patches/connection_handling.rb` — fix `load_tenant_schema_cache` to use `schema_reflection=`.
- `docs/caching.md` — add a `## Schema-cache recovery` section documenting the helper, its current-process / maintenance-window / model-reset limits, the deploy-restart guidance for fleet-wide and MySQL cases, and the shared-table amplifier. (Adjacent to the existing tenant-aware caching guidance; no new file.)
- `docs/designs/fixture-pool-lifecycle.md` — mark member 8's reactive recovery shipped; note the residual (cross-process proactive invalidation) stays deferred.

## Testing

- **Helper, schema_cache_per_tenant off (default)**: warm two tenant pools, populate caches, run DDL on a shared/pinned table, call `reload_schema_cache!`, assert each warm pool's cache (and the default pool's) is cleared and repopulates with the new schema. Single-tenant arg clears only that tenant.
- **Default pool inclusion**: assert `ActiveRecord::Base.connection_pool.schema_cache` is cleared by the no-arg call (the catch `PoolManager` misses).
- **clear!-repopulates-from-DB-not-file**: with `schema_cache_per_tenant: true` and a stale dump on disk, assert post-`reload_schema_cache!` reflection matches the DB, not the stale file.
- **Bundled bug fix round-trip**: `schema_cache_per_tenant: true`, dump a tenant cache, establish the pool, assert it loads from the file (no DB reflection query) and no `ArgumentError` is raised. Regression-locks the `load!` → `schema_reflection=` fix.
- **Engine/Rails matrix**: PG primary (schema strategy); the API (`schema_reflection=`, `SchemaReflection.new`, `clear!`) is stable across Rails 7.2/8.0/8.1 — verify via existing appraisals.

## Cross-references

- `docs/designs/fixture-pool-lifecycle.md` — failure-class member 8 (this design closes the reactive half).
- `docs/designs/v4-beta-readiness.md` — W2; this is the member-8 workstream, descoped from "design-first long pole" to "minimal helper + bundled fix" after the architecture review.
- `docs/designs/apartment-v4.md` — pool-per-tenant connection model; per-pool schema cache.
- `lib/apartment/patches/connection_handling.rb` — per-tenant pool establishment; the `schema_cache_per_tenant` load path being fixed.
- `lib/apartment/schema_cache.rb` — per-tenant dump helper (`dump`, `cache_path_for`).

## Origin

2026-06-29 member-8 brainstorm. Investigation showed v4's pool-per-tenant architecture already mitigates most of member 8's v3 framing (per-pool caches + AR prepared-statement self-heal). A four-agent panel (Codex, Gemini, Cursor, Mistral) confirmed the minimal-helper leans (Option A, schema-cache-only, manual-only) and surfaced the default-pool and model-cache catches folded in above. The `schema_cache_per_tenant` `load!` bug was found while verifying the panel's API claims against ActiveRecord source.
