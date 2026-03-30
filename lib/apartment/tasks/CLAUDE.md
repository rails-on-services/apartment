# lib/apartment/tasks/ - Rake Task Infrastructure

This directory contains v4 rake task definitions for Apartment tenant operations.

## Files

### v4.rake

**Purpose**: Defines the `apartment:` rake task namespace for tenant lifecycle operations.

**Tasks**:
- `apartment:create` — Create tenant schemas/databases for all configured tenants
- `apartment:drop` — Drop tenant schemas/databases for all configured tenants
- `apartment:migrate` — Run migrations across all tenant schemas/databases
- `apartment:seed` — Seed all tenant schemas/databases
- `apartment:rollback` — Roll back migrations across all tenant schemas/databases

**Loading**: Loaded by `Railtie#rake_tasks` hook (see `lib/apartment/railtie.rb`). Not loaded outside a Rails context.

## Relationship to Other Components

- **Railtie** (`lib/apartment/railtie.rb`): Loads `tasks/v4.rake` via the `rake_tasks` block.
- **Tenant API** (`lib/apartment/tenant.rb`): Tasks delegate lifecycle operations to `Apartment::Tenant`.
- **Configuration** (`lib/apartment/config.rb`): Tasks respect `Apartment.config` (tenants_provider, excluded_models, etc.).

## Notes

v3 task helpers (`task_helper.rb`, `enhancements.rb`, `schema_dumper.rb`) and the top-level `lib/tasks/apartment.rake` have been deleted as of Phase 2.5. v4 tasks are simpler — sequential-only iteration, no parallel migration support (intentional; parallel migration adds complexity with marginal benefit for the v4 pool-per-tenant model).
