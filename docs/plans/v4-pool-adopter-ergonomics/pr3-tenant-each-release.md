# `Tenant.each(release_connection:)` + iteration guide — Implementation Plan (PR 3)

**Goal:** Let `Apartment::Tenant.each` release the leased connection between tenants so pools become reap-eligible mid-fan-out, and document how to choose a cross-tenant iteration primitive.

**Design spec:** `docs/designs/v4-pool-adopter-ergonomics.md` (component B).

**Branch:** `feat/tenant-each-release` off `main`.

**Doc placement note:** the design put the iteration guide in `docs/observability.md`; the README ("Background Workers" / "Convenience Methods") is the more discoverable home for usage guidance, so it goes there instead.

---

### Task 1: `Tenant.each(release_connection: false)`

**Files:** `lib/apartment/tenant.rb`, `spec/unit/tenant_spec.rb`

```ruby
def each(tenants = nil, release_connection: false)
  raise(ArgumentError, 'Apartment::Tenant.each requires a block') unless block_given?

  tenants ||= Apartment.tenant_names
  tenants.each do |tenant|
    switch(tenant) { yield(tenant) }
    # v4 keys a pool per "tenant:role"; the switch leaves a leased connection
    # that keeps the pool un-reapable. Release it so a long fan-out doesn't hold
    # one warm connection per visited tenant. Handler-wide (:all) covers writing
    # + reading roles — the gem's established release call (see memory_stability_spec).
    ActiveRecord::Base.connection_handler.clear_active_connections!(:all) if release_connection
  end
end
```

Default `false` preserves current behavior. Unit specs (spy on the real handler — real AR is loaded in `tenant_spec`):

```ruby
it 'releases the connection after each tenant when release_connection: true' do
  allow(ActiveRecord::Base.connection_handler).to(receive(:clear_active_connections!))
  described_class.each(release_connection: true) { |_t| }
  expect(ActiveRecord::Base.connection_handler)
    .to(have_received(:clear_active_connections!).with(:all).twice)   # 2 tenants
end

it 'does not release connections by default' do
  allow(ActiveRecord::Base.connection_handler).to(receive(:clear_active_connections!))
  described_class.each { |_t| }
  expect(ActiveRecord::Base.connection_handler).not_to(have_received(:clear_active_connections!))
end
```

TDD + commit.

---

### Task 2: Integration proof (release makes pools reap-eligible)

**Files:** `spec/integration/v4/tenant_each_release_spec.rb` (new)

Mirror `memory_stability_spec` setup (V4IntegrationHelper, skip on sqlite). Create N tenants with a `widgets` table, then:

```ruby
it 'leaves no leased connection on visited pools when release_connection is true' do
  stub_const('Widget', Class.new(ActiveRecord::Base) { self.table_name = 'widgets' })
  role = ActiveRecord::Base.current_role

  Apartment::Tenant.each(release_connection: true) { Widget.create!(name: 'x') }

  tenants.each do |t|
    pool = Apartment.pool_manager.peek("#{t}:#{role}")
    expect(pool).not_to(be_nil)
    expect(pool.connections.any?(&:in_use?)).to(be(false), "#{t} pool still has a leased connection")
  end
end

it 'leaves leased connections without release_connection (contrast)' do
  stub_const('Widget', Class.new(ActiveRecord::Base) { self.table_name = 'widgets' })
  role = ActiveRecord::Base.current_role

  Apartment::Tenant.each { Widget.create!(name: 'x') }

  leased = tenants.any? do |t|
    pool = Apartment.pool_manager.peek("#{t}:#{role}")
    pool && pool.connections.any?(&:in_use?)
  end
  expect(leased).to(be(true))
ensure
  ActiveRecord::Base.connection_handler.clear_active_connections!(:all)
end
```

TDD + commit. Run on PostgreSQL: `DATABASE_ENGINE=postgresql BUNDLE_GEMFILE=gemfiles/rails_8.1_postgresql.gemfile bundle exec rspec spec/integration/v4/tenant_each_release_spec.rb`.

---

### Task 3: Iteration guide (README)

**Files:** `README.md`

Add an "## Iterating across tenants" section after "Background Workers":

- One question — *does the block do per-tenant-schema work?* — and a table:

| Need | Use | v4 cost |
|---|---|---|
| Names only (enqueue, list) | `Apartment.tenant_names.each { ... }` | No switch, no pool created |
| Per-tenant-schema work | `Apartment::Tenant.each(release_connection: true) { ... }` | One pool per tenant; released between iterations |
| Global/pinned data only | Don't switch — read it in the default context | A switch resolves pinned models *through* the tenant pool |

- The gotcha: under shared-pinned-connections a `switch` routes pinned/excluded models through the current tenant's pool, so switching only to read global data spins up a tenant pool for nothing.
- Note `release_connection: true` for large fan-outs (keeps pools reap-eligible).

Commit.

---

### Task 4: Verify + review

- `bundle exec rspec spec/unit/tenant_spec.rb` + full unit suite — green
- Integration: PostgreSQL (+ MySQL if available) for `tenant_each_release_spec`
- `bundle exec rubocop` on changed files — clean
- Cross-version unit smoke (7.2 + 8.1)
- Adversarial panel review (standard) → address findings → PR `feat/tenant-each-release` → `main`
