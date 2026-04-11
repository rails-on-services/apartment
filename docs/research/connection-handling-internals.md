# ActiveRecord Connection Handling Internals — Research for Phase 2.3

> Research notes for Apartment v4's `ConnectionHandling` patch.
> Covers AR pool resolution across Rails 7.2/8.0/8.1, prior art from other gems, and rationale for our approach.

## ActiveRecord Pool Resolution Architecture

### The lookup path (stable across 7.2–8.1)

```
ActiveRecord::Base.connection_pool
  → connection_handler.retrieve_connection_pool(
      connection_specification_name,
      role: current_role,
      shard: current_shard,
      strict: true
    )
  → @connection_name_to_pool_manager[connection_name]   # Concurrent::Map
  → PoolManager#get_pool_config(role, shard)            # Hash[role][shard]
  → PoolConfig#pool                                     # the actual ConnectionPool
```

Pools are keyed by the tuple `(connection_name, role, shard)`. The `connection_name` is typically `"ActiveRecord::Base"` for the primary connection class. Shards are symbols.

### `current_shard` resolution

`current_shard` walks the `connected_to_stack` (a fiber-local array) in reverse, looking for the first entry whose `klasses` includes the current connection class. Falls back to `default_shard` (`:default`).

This stack is what `connected_to(shard: :foo) { ... }` pushes to and pops from.

### `establish_connection` on ConnectionHandler

Signature (identical across 7.2/8.0/8.1):

```ruby
def establish_connection(config, owner_name: Base, role: Base.current_role,
                         shard: Base.current_shard, clobber: false)
```

Key behaviors:
- **Idempotent**: If an existing pool has the same `db_config`, returns that pool (no duplicate creation).
- **Lazy**: In Rails 7.2+, pool is created but no connection is established until the first query.
- **Thread-safe**: `@connection_name_to_pool_manager` is a `Concurrent::Map`. `PoolManager` stores `PoolConfig` objects in a plain `Hash`, but access is synchronized by the handler.
- Accepts `owner_name` as a class or string/symbol. Strings are wrapped in an internal descriptor.

### API differences across Rails versions

| Aspect | 7.2 | 8.0 | 8.1 |
|--------|-----|-----|-----|
| `PoolConfig` owner field | `connection_class` | `connection_descriptor` | `connection_descriptor` |
| `ConnectionHandler` string wrapper | `StringConnectionName` | `ConnectionDescriptor` | `ConnectionDescriptor` |
| `set_pool_manager` key | `.connection_name` (string) | `.connection_descriptor` (object) | `.connection_descriptor` (object) |
| `establish_connection` public API | identical | identical | identical |
| `remove_connection_pool` public API | identical | identical | identical |
| `shard_keys` tracking | not tracked | not tracked | `@shard_keys` on connection class |
| `connected_to_all_shards` | not present | not present | iterates `shard_keys` |

**Key takeaway**: The `connection_class` → `connection_descriptor` rename in 8.0 is internal to `PoolConfig`. The public API we use (`establish_connection`, `remove_connection_pool`, `retrieve_connection_pool`) is stable across all three versions.

### `remove_connection_pool` — pool cleanup

```ruby
def remove_connection_pool(connection_name, role:, shard:)
  pool_manager = get_pool_manager(connection_name)
  pool_config = pool_manager.remove_pool_config(role, shard)
  pool_config.disconnect!  # calls pool.disconnect!
end
```

Stable API across 7.2–8.1. This is what our PoolReaper must call during eviction.

### `prohibit_shard_swapping`

Rails provides `prohibit_shard_swapping` to prevent nested shard switches (e.g., in per-request database isolation). If user code calls this, and we use shard-based pool keying, our tenant switch would raise.

**Our mitigation**: We override `connection_pool` directly rather than using `connected_to(shard:)`. Our patch reads `Apartment::Current.tenant` and calls `establish_connection` / `retrieve_connection_pool` with a specific shard key. This bypasses `connected_to_stack` entirely, so `prohibit_shard_swapping` does not affect us.

### Rails 8.1 `shard_keys` tracking

Rails 8.1 tracks `@shard_keys` set via `connects_to shards: { ... }`. Our dynamically created tenant shards will NOT appear in this list. `connected_to_all_shards` will not iterate our tenants.

This is fine — Apartment has its own `tenants_provider` and `Tenant.switch` API for iterating tenants. We should document this distinction.

---

## Prior Art: Other Multi-Tenancy Approaches

### Basecamp's `activerecord-tenanted` (2025)

**Repo**: [basecamp/activerecord-tenanted](https://github.com/basecamp/activerecord-tenanted)

**Approach**: Extends ActiveRecord to dynamically create a `ConnectionPool` per tenant on demand, using Rails' horizontal sharding infrastructure. Each tenant is treated as a shard. The `tenanted` macro on `ApplicationRecord` enables tenant-aware connections.

**Key design choices**:
- `with_tenant("acme") { ... }` — block-scoped tenant context (analogous to our `Tenant.switch`)
- Database path uses `%{tenant}` interpolation in `database.yml` (e.g., `storage/production/%{tenant}/main.sqlite3`)
- `max_connection_pools` config limits active tenant connections
- Integrates with Action Dispatch, Active Job, Action Cable, Turbo, Active Storage, etc.
- Currently SQLite-only; PostgreSQL support is being explored ([#194](https://github.com/basecamp/activerecord-tenanted/discussions/194), [#261](https://github.com/basecamp/activerecord-tenanted/pull/261))

**Relevance to Apartment v4**: Validates the "tenant as shard" approach. Their gem is designed for the ONCE/Writebook model (SQLite file-per-tenant). Apartment targets a broader range: PostgreSQL schemas, PostgreSQL databases, MySQL databases, and SQLite files — with schema-based tenancy (shared DB, isolated namespaces) being the most common production pattern.

**Key difference**: `activerecord-tenanted` uses `database.yml` interpolation for tenant config resolution. Apartment v4 uses adapter-specific `resolve_connection_config` methods, which is more flexible for schema-based tenancy where the database is shared but the `schema_search_path` differs per tenant.

### Julik's "A Can of Shardines" (April 2025)

**Blog post**: [blog.julik.nl/2025/04/a-can-of-shardines](https://blog.julik.nl/2025/04/a-can-of-shardines)

**Context**: Author struggled with Apartment's thread-safety issues (#304) and documented the journey to a correct SQLite-per-tenant solution using Rails' `connected_to` API.

**Key insights**:
1. **`establish_connection` is not the right API for per-request switching** — it was designed for static, boot-time configuration. The correct approach is to pre-register connection pools and use `connected_to(role:)` or `connected_to(shard:)` to switch.
2. **Lazy pool registration**: Check if a pool exists for the tenant's role/shard; if not, call `establish_connection` on the `ConnectionHandler` to register it. Protect with a mutex.
3. **Streaming Rack bodies**: The `connected_to` block-based API doesn't work for streaming responses. Julik solves this with a `Fiber` that enters the `connected_to` block, yields, and resumes on `body.close`.
4. **Database servers vs. SQLite**: Database servers are optimized for few large databases; SQLite thrives with many small ones. This informs why Apartment's PostgreSQL schema strategy (one DB, many schemas) is the right pattern for server DBs.

**Relevance to Apartment v4**: Reinforces that the pool-per-tenant approach is sound. Apartment v4's `CurrentAttributes`-based context handles the streaming body concern differently — `Current.tenant` persists across the fiber/thread boundary naturally (since `CurrentAttributes` uses `IsolatedExecutionState`), so we don't need the Fiber trick. Our `connection_pool` override reads `Current.tenant` on every pool lookup, which works regardless of whether we're in a `call` or a streaming body.

### Discussion: #194 — MySQL and PostgreSQL support for activerecord-tenanted

**Status (as of March 2026)**: Maintainer @flavorjones is working on isolating SQLite-specific code. PR #204 (merged) separated create/destroy logic. Draft PR #261 adds PostgreSQL support but is still WIP.

**Key takeaway**: The `activerecord-tenanted` gem is SQLite-first by design. Adding PostgreSQL/MySQL support is non-trivial because schema-based tenancy (shared DB, different `search_path`) has different lifecycle semantics than file-based tenancy. This is exactly what Apartment has solved for over a decade.

---

## Our Approach: Tenant-as-Shard with Namespaced Keys

### Why shard-based keying

AR's pool resolution uses `(connection_name, role, shard)`. We map tenants to shards because:
1. **Minimal patching**: We override `connection_pool` on `ActiveRecord::Base` to return a tenant-specific pool. The pool is registered via AR's standard `establish_connection` with `shard: namespaced_key`.
2. **AR compatibility**: Pools live inside AR's `ConnectionHandler`, so `database_cleaner`, `strong_migrations`, and other gems that inspect `ActiveRecord::Base.connection_pool` see the correct pool.
3. **Lazy creation**: Pools are created on first access and cached in both our `PoolManager` (for timestamps/eviction) and AR's `ConnectionHandler` (for pool lifecycle).

### Why namespaced shard keys

User apps may already use `connects_to shards: { ... }`. Bare tenant names (`:acme`) could collide with user-defined shards. We namespace with a configurable prefix:

```ruby
shard_key = :"#{Apartment.config.shard_key_prefix}_#{tenant}"
# Default: :apartment_acme
```

The prefix is configurable via `config.shard_key_prefix` (default: `"apartment"`).

### Data isolation guarantee

Each tenant gets its own `ConnectionPool` with tenant-specific config baked in at creation time:
- **PostgreSQL (schema strategy)**: `schema_search_path: '"acme","ext","public"'` — the connection can only see tables in these schemas.
- **PostgreSQL/MySQL (database strategy)**: `database: "acme_production"` — the connection points at a different database entirely.
- **SQLite**: `database: "storage/acme.sqlite3"` — a different file.

Because the config is **immutable per pool**, a connection checked out from tenant A's pool cannot accidentally execute queries against tenant B's data. There is no `SET search_path` at switch time — the pool's connections are pre-configured. This eliminates the class of tenant leakage bugs that motivated v4.

### How eviction integrates with AR's handler

When `PoolReaper` evicts a tenant pool, it must:
1. Remove from `Apartment::PoolManager` (our tracking)
2. Call `connection_handler.remove_connection_pool("ActiveRecord::Base", role: :writing, shard: namespaced_key)` — this disconnects the pool and deregisters it from AR's handler

### Complications and mitigations

| Concern | Mitigation |
|---------|------------|
| `prohibit_shard_swapping` blocks our shard switches | We override `connection_pool` directly, bypassing `connected_to_stack` |
| Rails 8.1 `shard_keys` won't include our tenants | We have `tenants_provider` for iteration; document the distinction |
| User-defined shards collide with tenant shards | Configurable `shard_key_prefix` (default: `"apartment"`) |
| `establish_connection` re-resolves config on each call | AR's idempotent check returns existing pool if config matches; our `PoolManager.fetch_or_create` prevents redundant calls |

---

## References

- ActiveRecord source: `activerecord/lib/active_record/connection_handling.rb`
- ActiveRecord source: `activerecord/lib/active_record/connection_adapters/abstract/connection_handler.rb`
- ActiveRecord source: `activerecord/lib/active_record/connection_adapters/pool_manager.rb`
- ActiveRecord source: `activerecord/lib/active_record/connection_adapters/pool_config.rb`
- [basecamp/activerecord-tenanted](https://github.com/basecamp/activerecord-tenanted) — GUIDE.md, discussion #194, PR #261
- [Julik Tarkhanov, "A Can of Shardines"](https://blog.julik.nl/2025/04/a-can-of-shardines) — April 2025
- [Rails Guides: Multiple Databases](https://guides.rubyonrails.org/active_record_multiple_databases.html)
