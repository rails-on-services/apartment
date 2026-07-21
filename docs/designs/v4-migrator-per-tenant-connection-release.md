# Migrator: release each tenant's connection after migrating

**Status**: designed 2026-07-21, from a deploy-time pool-pressure incident
(2026-07-20). Ships in `4.0.0.alpha10`.

## Verdict

- **The Migrator leaks a leased connection per tenant.**
  `Apartment::Tenant.switch(tenant) { }` restores `Current.tenant` on block exit
  but never checks the connection back in. In a rake process (no Rails executor to
  release on request end), each worker thread's connection to the just-migrated
  tenant's pool stays `in_use?` until end of run.
- **That leak is the deploy-flood amplifier.** A leased pool is non-evictable:
  `PoolReaper#pool_in_use?` → `protected_pool?` skips it (`:skip_evict`), and
  admission can't meet the cap (`:cap_unmet`). Finished-but-leased pools are
  re-scanned on every cold admission — 34,879 `skip_evict` + 314 `cap_unmet` in
  ~2 min during the 2026-07-20 deploy.
- **Fix: release the worker's own lease after each tenant.** In `migrate_tenant`'s
  existing `ensure`, best-effort `tenant_pool&.release_connection` on the pool
  captured inside the `switch` block. Execution-context scoped — releases only the
  calling worker's lease, cannot touch another thread's active pool (the hard
  constraint). See [decisions](#decisions).
- **Targeted release, not handler-wide `clear_active_connections!(:all)`.**
  `migrate_tenant` is shared by the parallel, sequential, and single-tenant
  (`migrate_one`) paths; the latter two run on a **caller-owned** execution context
  that may hold other leases. Handler-wide `:all` would release the caller's
  unrelated connections there. Targeted per-pool release is safe on every path.
- **No per-tenant pool teardown.** Release makes the pool evictable; admission /
  the reaper / the end-of-run `evict_migration_pools` remove it. Mid-run per-tenant
  removal has a TOCTOU (another context can re-acquire the key before removal) and
  a shared-role hazard — deliberately excluded.
- **The card's acceptance was mis-stated and is corrected here.**
  `TenantPoolsLive` counts *registered* pools, not leased ones, so release alone
  does not drive that gauge to thread-count. See
  [acceptance](#acceptance-corrected).

## Mechanism

`migrate_tenant` leases a connection on the worker thread and never releases it:

```ruby
def migrate_tenant(tenant)
  Apartment::Current.migrating = true
  with_migration_role do                       # connected_to(role: migration_role)
    Apartment::Tenant.switch(tenant) do
      context = ActiveRecord::Base.connection_pool.migration_context
      # ... context.migrate leases a connection on THIS thread ...
    end
  end
ensure
  Apartment::Current.migrating = false         # connection is NEVER checked back in
end
```

`switch` only sets/restores `Current.tenant`; `with_migration_role` /
`connected_to` only swap the active role. Neither checks a connection in. Under a
web request the Rails executor releases on request end; a rake process has no such
boundary, so the lease persists to end of run.

The amplifier, in `PoolReaper`:

```ruby
def pool_in_use?(pool)
  pool.connections.any? { |c| c.in_use? || c.open_transactions.positive? }
end
# true => protected_pool? emits :skip_evict and refuses eviction;
#         cap can't be met => :cap_unmet, re-evaluated on every cold admission.
```

## Design

Single change, in `lib/apartment/migrator.rb`, `migrate_tenant` only:

1. Capture the tenant pool as the **first statement inside the `switch` block**
   (before the `needs_migration?` check, so the skip path is covered too):
   `tenant_pool = ActiveRecord::Base.connection_pool`.
2. In the existing `ensure`, after `Apartment::Current.migrating = false`, add
   best-effort release:

   ```ruby
   begin
     tenant_pool&.release_connection
   rescue StandardError => e
     warn "[Apartment::Migrator] connection release failed: #{e.class}: #{e.message}"
   end
   ```

`release_connection` is public `ActiveRecord::ConnectionAdapters::ConnectionPool`
API across the supported Rails 7.2–8.1 matrix. It releases the current execution
context's lease on that specific pool and no-ops when nothing is leased.

**Untouched by design:**

- `migrate_primary` — uses the app's default pool on the main thread; that pool is
  eviction-protected (`default_tenant_pool?`) and must not be released here.
- End-of-run `evict_migration_pools` — role-scoped bulk teardown; release does not
  replace it.

**Why the release is best-effort:** a release failure must never mask a migration
error or corrupt the returned `Result`. Same rescue+warn posture as
`Tenant.each(release_connection:)`.

## Decisions

### Targeted `release_connection` over handler-wide `:all`

`clear_active_connections!(:all)` (the `Tenant.each` idiom) is tempting for
consistency, but the decider is safety: because the release lives in
`migrate_tenant`, and
`migrate_one` / the sequential path run on a **caller-owned** execution context,
handler-wide `clear_active_connections!(:all)` would release the caller's unrelated
leases (default pool, an outer connection) on those paths.
`Tenant.each(release_connection:)` gets away with `:all` only because the breadth
is gated behind an opt-in flag the caller chooses. Here it would be unconditional.
Targeted per-pool release is safe regardless of caller and makes the
"don't-affect-others" constraint visible in the code.

### No `:all` fallback when `tenant_pool` is nil

`tenant_pool` is captured as the first line inside the `switch` block, before any
lease. It is nil only when we bailed *before* leasing anything (a raising
default-tenant guard or role switch) — so there is nothing of ours to release.
Everything `migrate_tenant` leases goes through the captured pool, so
`tenant_pool&.release_connection` is complete. A `:all` fallback would find nothing
of ours and, on the caller-owned paths, would release the caller's connections —
reintroducing the exact breadth hazard targeted release avoids. A regression test
asserting zero busy connections after each tenant guards a future off-pool lease.

### No per-tenant pool removal

Removing the tenant's migration pool mid-run to shrink the *registered*-pool gauge
would need an identity-checked, admission-coordinated eviction primitive — the
existing `evict_migration_pools` drops **all** migration-role pools and can
disconnect a pool another worker is using. Two hazards make direct per-tenant
removal unsafe: TOCTOU (another context re-acquires the key between release and
remove) and shared-role teardown (dropping `:writing` when no distinct
`migration_role` is configured). Release + existing eviction paths already resolve
the incident.

## Acceptance (corrected)

The card asked for `TenantPoolsLive ~thread-count`. `TenantPoolsLive` is
`PoolObserver#sample!` emitting `PoolManager#stats[:total_pools]` — a count of
**registered** pools, not leased ones. Releasing a connection makes a pool
evictable but does not deregister it, so that gauge stays bounded by the cap
(`max_tenant_pools`), not thread-count. The count that tracks ~thread-count is the
*busy/leased* pool count. Corrected, verifiable acceptance:

- `skip_evict` with `reason: :in_use` → ~0 during a parallel migrate.
- `cap_unmet` → ~0 during the deploy window.
- Busy/leased migration pools ~thread-count (at most one per worker at a time).
- `TenantPoolsLive` (registered pools) bounded by the cap.
- Migration correctness unchanged.

## Testing

- **Parallel migrate under a cap** (integration): after each tenant completes, its
  migration pool reports **0 busy connections and 0 open transactions**; assert
  `skip_evict`/`cap_unmet` do not grow; assert `total_pools` stays bounded by the
  cap.
- **Failure path**: a raising migration still releases the connection — assert
  `in_use? == false` **and** `open_transactions == 0` afterward (Rails rolls the
  migration transaction back; prove release doesn't leave a dirty, still-protected
  connection).
- **Skip path**: an up-to-date tenant (`needs_migration?` false) releases cleanly
  (no-op or real, never an error).
- **Sequential + `migrate_one`**: release fires and does not disturb a caller-held
  connection.

## Scope boundary

- Version bump `4.0.0.alpha9` → `4.0.0.alpha10`, in this PR.
- Adopting apps pick up the fix by bumping their `ros-apartment` dependency; no
  adopter code change is required.
