# Phase 8: Documentation & Upgrade Guide

## Goal

Make v4 shippable by rewriting user-facing documentation to reflect the v4 API, providing a self-sufficient upgrade guide for external users, and updating maintainer docs for dual-release support (v4 + v3 maintenance).

## Deliverables

### 1. `docs/history/` — Legacy Documentation

Move legacy files from root into `docs/history/`:

| Current path | New path |
|---|---|
| `legacy_CHANGELOG.md` | `docs/history/CHANGELOG-v3.md` |
| (current README.md content) | `docs/history/README-v3.md` |

`README-v3.md` gets a header: "This documents Apartment v3.x. For v4, see [README.md](../../README.md)."

`CHANGELOG-v3.md` gets a similar header pointing to GitHub Releases for v4+.

### 2. `README.md` — v4 Rewrite

Complete rewrite oriented around v4's mental model. Structure:

```
# Apartment
  [badges]
  One-liner + code example

## When to Use Apartment
  [keep current comparison table — it's good]

## About ros-apartment
  [keep, minor update: note v4 rewrite]

## Installation
  Requirements (Ruby 3.3+, Rails 7.2+, PG 14+/MySQL 8.4+/SQLite3)
  Gemfile + generator command

## Quick Start
  Apartment.configure block with:
    - config.tenant_strategy (required, :schema or :database_name)
    - config.tenants_provider (required, callable)
    - config.default_tenant
  Apartment::Tenant.create / switch / drop examples
  Apartment::Model + pin_tenant for global models

## Configuration Reference
  ### Required Options
    tenant_strategy, tenants_provider
  ### Pool Settings
    tenant_pool_size, pool_idle_timeout, max_total_connections
  ### Elevator (Request Tenant Detection)
    config.elevator, config.elevator_options
    Note: Railtie auto-inserts middleware; no manual insertion needed
  ### Migrations
    parallel_migration_threads, schema_load_strategy, seed_after_create
  ### RBAC
    migration_role, app_role, environmentify_strategy
  ### PostgreSQL
    configure_postgres { |pg| pg.persistent_schemas = [...] }
    Shared extensions setup (keep existing rake example)
  ### MySQL
    configure_mysql { |my| ... }

## Elevators
  [keep current content, update examples to v4 patterns]
  Note Railtie auto-insertion
  Custom elevator example

## Pinned Models (Global Tables)
  Replaces "Excluded Models" section.

  Models that live in the default schema (not per-tenant):
    include Apartment::Model
    pin_tenant

  Why pin_tenant over excluded_models:
    - Declarative: the model itself declares its tenancy, not a config list
    - Zeitwerk-safe: works with autoloading (no string-to-class resolution at boot)
    - Composable: works with connected_to(role:) for read replicas

  Association rule: use has_many :through, not HABTM.

  connected_to compatibility:
    Pinned models work correctly inside connected_to(role: :reading) blocks.
    The pin bypasses Apartment's tenant routing; Rails' own role routing
    takes over. No special handling needed.

## Callbacks
  [keep current content, same API]

## Migrations
  [keep content, update rake task names to apartment:migrate etc.]
  Parallel migrations section (keep)

## Known Limitations
  ### connects_to with Separate Databases
    If a model (or its abstract base class) uses connects_to to point at
    a completely different database (not just different roles on the same DB),
    Apartment's connection_pool patch will try to create a tenant pool for it.

    Workaround: pin_tenant on the abstract class or model that declares
    connects_to to a separate database.

    Note: The common pattern of ApplicationRecord using connects_to with
    multiple roles (writing/reading) on the same database works correctly —
    Apartment keys pools by "tenant:role" and respects Rails' role routing.

## Background Workers
  [keep, update examples to block-based switch]

## Rails Console
  [keep current content]

## Troubleshooting
  [keep, remove any v3-only items]

## Upgrading from v3
  Link to docs/upgrading-to-v4.md

## Contributing
  [keep, update test commands if needed]

## License
  [keep]
```

Things explicitly removed from README:
- `config.excluded_models` (upgrade guide only)
- `config.tenant_names` (upgrade guide only)
- `config.use_schemas` / `config.use_sql` (replaced by `tenant_strategy` and `schema_load_strategy`)
- `switch!` recommendation (mention it exists for console use, discourage in app code)
- Multi-server setup (not yet ported to v4; omit rather than document unimplemented feature)

### 3. `docs/upgrading-to-v4.md` — Upgrade Guide

Self-sufficient guide for external ros-apartment users upgrading from v3 to v4.

Structure:

```
# Upgrading to Apartment v4

## Requirements
  Ruby 3.3+, Rails 7.2+, PostgreSQL 14+, MySQL 8.4+, SQLite3

## What Changed and Why
  Brief (3-4 sentences): pool-per-tenant replaces thread-local switching,
  fiber-safe via CurrentAttributes, immutable config after boot, declarative
  model pinning.

## Breaking Changes

  ### Configuration
    - tenant_names removed; use tenants_provider (must be callable)
    - tenant_strategy required (:schema or :database_name)
    - use_schemas / use_sql removed; use tenant_strategy + schema_load_strategy
    - Config is frozen after Apartment.configure — no runtime mutation

  ### Tenant API
    - Apartment::Tenant.switch requires a block (no manual switch/reset pattern)
    - switch! exists for console/REPL but is discouraged in app code
    - current_tenant removed; use Apartment::Tenant.current

  ### Models
    - config.excluded_models removed
    - Use: include Apartment::Model + pin_tenant on each global model
    - process_excluded_models removed; use process_pinned_models

  ### Middleware
    - Railtie auto-inserts elevator middleware; remove manual
      config.middleware.use/insert_before lines
    - Configure via config.elevator = :subdomain (symbol, not class)

  ### Connection Model
    - Pool-per-tenant replaces thread-local switching
    - Fiber-safe via CurrentAttributes (set isolation_level: :fiber if using fibers)
    - Each tenant gets a dedicated connection pool

## Migration Steps

  ### Step 1: Update Configuration
    Before/after config comparison

  ### Step 2: Update Models
    For each model in config.excluded_models:
      1. Add include Apartment::Model
      2. Add pin_tenant
      3. Remove from config.excluded_models list
    Delete the config.excluded_models line.

  ### Step 3: Update Tenant Switching
    Find/replace patterns:
      switch_to(t) ... ensure reset! → switch(t) { ... }
      Apartment::Tenant.current_tenant → Apartment::Tenant.current

  ### Step 4: Update Middleware
    Remove manual middleware insertion.
    Set config.elevator = :subdomain (or appropriate symbol).

  ### Step 5: Update Background Jobs
    Block-scoped switching in Sidekiq/ActiveJob workers.

  ### Step 6: Update Tests
    before { Apartment::Tenant.reset } (no bang)
    Block-based switching in specs

  ### Step 7: Verify
    Run full test suite
    Check connection pool behavior in staging

## connects_to Compatibility
  Same content as README "Known Limitations" section, with more detail:
  - The common case (ApplicationRecord connects_to with roles) works
  - Edge case: model with connects_to to a separate database needs pin_tenant
  - connected_to(role: :reading) works correctly with pinned models

## Troubleshooting
  Port useful items from PR #327 (corrected):
  - "No connection defined for tenant" → check tenants_provider
  - Connection pool sizing → tenant_pool_size, max_total_connections
  - Thread safety → always use block-scoped switch
  Remove: inflated benchmarks, emoji headers, inaccurate API claims
```

### 4. Install Template Update

`lib/generators/apartment/install/templates/apartment.rb` line 21 area.

Current:
```ruby
# Models that live in the shared/default schema (not per-tenant).
# config.excluded_models = %w[Account]
```

Replace with:
```ruby
# Models that live in the shared/default schema (not per-tenant).
# The recommended approach is to declare this in the model itself:
#
#   class Account < ApplicationRecord
#     include Apartment::Model
#     pin_tenant
#   end
#
# Legacy alternative (deprecated, will be removed in v5):
# config.excluded_models = %w[Account]
```

### 5. `RELEASING.md` — Dual Release Process

Add a section covering the v3 maintenance track:

```
## Dual Release (v4 + v3 maintenance)

While v3 is still supported, maintenance releases (bug fixes, security
patches) are cut from the `v3-stable` branch.

### v4 releases
Same as current process: development → main → publish.

### v3 maintenance releases

The gem-publish workflow currently triggers on push to `main` only.
For v3 releases, we add a tag trigger to the workflow:

```yaml
on:
  push:
    branches: [ 'main' ]
    tags: [ 'v3.*' ]
```

Release steps:
1. Create/checkout `v3-stable` branch (branched from last v3 release tag)
2. Cherry-pick or apply fixes (e.g., PRs #340, #342)
3. Bump version in lib/apartment/version.rb (e.g., 3.4.2)
4. Push v3-stable to origin
5. Tag and push: `git tag v3.4.2 && git push origin v3.4.2`
   - The tag push triggers gem-publish, which checks out the tag
   - Do NOT merge v3-stable into main (main contains v4 code)
6. Create GitHub Release from the v3.4.2 tag, noting it as a maintenance release

### Version coordination
- v4 uses 4.x.y version numbers
- v3 maintenance uses 3.4.x version numbers
- Both publish to the same ros-apartment gem on RubyGems
- RubyGems resolves via version constraints in user Gemfiles

### End of v3 support
When v3 maintenance ends, delete the v3-stable branch and remove this
section from RELEASING.md.
```

### 6. CLAUDE.md Updates

#### Root `CLAUDE.md`

- **Core Concepts**: Add `pin_tenant` mention: "**Pinned models**: Global tables declared with `Apartment::Model` + `pin_tenant`. Replaces `excluded_models`."
- **Commands**: Verify test counts are current; update if spec counts changed since last edit.
- **Gotchas**: Add note about `connects_to` edge case.

#### `lib/apartment/CLAUDE.md`

Add to directory structure:
```
├── concerns/              # ActiveRecord concerns for tenant-aware models
│   └── model.rb               # Apartment::Model concern: pin_tenant, apartment_pinned?
```

Add file description section:
```
### concerns/model.rb — Model Pinning Concern

`Apartment::Model` provides `pin_tenant` (class method) to declare a model
as pinned to the default tenant. Registered models bypass the ConnectionHandling
patch. Zeitwerk-safe: works whether called before or after activate!.
`apartment_pinned?` checks the class and its superclass chain.
```

#### `spec/CLAUDE.md`

Add to the unit test file listing:
```
- `concerns/model_spec.rb` - Apartment::Model concern (pin_tenant, apartment_pinned?, inheritance)
- `patches/connection_handling_spec.rb` - ConnectionHandling patch (tenant pool routing, pinned model bypass, role keying)
```

### 7. `gem-publish.yml` — Tag Trigger for v3 Releases

Add `tags: [ 'v3.*' ]` to the workflow's `on.push` trigger so that v3 maintenance releases can be published from tags without merging into main.

## Non-Goals

- No application code changes (workflow config change is the only non-doc change)
- No v3 compatibility shims or deprecation warnings in code
- No multi-server setup documentation (not ported to v4 yet)
- No performance benchmarks (defer until real numbers exist)

## Open Questions

None — all resolved during brainstorming.
