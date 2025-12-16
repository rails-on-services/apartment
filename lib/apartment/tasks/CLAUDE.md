# lib/apartment/tasks/ - Rake Task Infrastructure

This directory contains modules that support Apartment's rake task operations, particularly tenant migrations with optional parallelism.

## Problem Context

Multi-tenant PostgreSQL applications using schema-per-tenant isolation face operational challenges:

1. **Migration time scales linearly**: 100 tenants × 2 seconds each = 3+ minutes of downtime
2. **Rails assumes single-schema**: Built-in migration tasks don't iterate over tenant schemas
3. **Parallel execution has pitfalls**: Database connections, advisory locks, and platform differences create subtle failure modes

## Files

### task_helper.rb

**Purpose**: Orchestrates tenant iteration for rake tasks with optional parallel execution.

**Key decisions**:

- **Result-based error handling**: Operations return `Result` structs instead of raising exceptions. This allows migrations to continue for other tenants when one fails, with aggregated reporting at the end.

- **Platform-aware parallelism**: macOS has documented issues with libpq after `fork()` due to GSS/Kerberos state. We auto-detect the platform and choose threads (safe everywhere) or processes (faster on Linux) accordingly. Developers can override via `parallel_strategy` config.

- **Advisory lock management**: Rails uses `pg_advisory_lock` to prevent concurrent migrations. With parallel tenant migrations, all workers compete for the same lock, causing deadlocks. We disable advisory locks during parallel execution. **This shifts responsibility to the developer** to ensure migrations are parallel-safe.

**When to use parallel migrations**:

Use when you have many tenants and your migrations only touch tenant-specific objects. Avoid when migrations create extensions, modify shared types, or have cross-tenant dependencies.

**Configuration options** (set in `config/initializers/apartment.rb`):

| Option | Default | Purpose |
|--------|---------|---------|
| `parallel_migration_threads` | `0` | Worker count. 0 = sequential (safest) |
| `parallel_strategy` | `:auto` | `:auto`, `:threads`, or `:processes` |
| `manage_advisory_locks` | `true` | Disable locks during parallel execution |

### schema_dumper.rb

**Purpose**: Ensures `schema.rb` is dumped from the public schema after tenant migrations.

**Why this exists**: After `rails db:migrate`, Rails dumps the current schema. Without intervention, this could capture the last-migrated tenant's schema rather than the authoritative public schema. We switch to the default tenant before invoking the dump.

**Rails convention compliance**: Respects `dump_schema_after_migration`, `database_tasks`, `replica`, and `schema_dump` settings from Rails configuration rather than inventing parallel config options.

### enhancements.rb

**Purpose**: Hooks Apartment tasks into Rails' standard `db:migrate` and `db:rollback` tasks.

**Design choice**: We enhance rather than replace Rails tasks. Running `rails db:migrate` automatically migrates all tenant schemas after the public schema.

## Relationship to Other Components

- **Apartment::Migrator** (`lib/apartment/migrator.rb`): The actual migration execution logic. TaskHelper coordinates which tenants to migrate; Migrator handles the per-tenant work.

- **Rake tasks** (`lib/tasks/apartment.rake`): Define the public task interface (`apartment:migrate`, etc.). These tasks use TaskHelper for iteration.

- **Configuration** (`lib/apartment.rb`): Parallel execution settings live in the main Apartment module.

## Common Failure Modes

### Connection pool exhaustion

**Symptom**: "could not obtain a connection from the pool" errors

**Cause**: `parallel_migration_threads` exceeds database pool size

**Fix**: Ensure `pool` in `database.yml` > `parallel_migration_threads`

### Advisory lock deadlocks

**Symptom**: Migrations hang indefinitely

**Cause**: Multiple workers waiting for the same advisory lock

**Fix**: Ensure `manage_advisory_locks: true` (default) when using parallelism

### macOS fork crashes

**Symptom**: Segfaults or GSS-API errors when using process-based parallelism on macOS

**Cause**: libpq doesn't support fork() cleanly on macOS

**Fix**: Use `parallel_strategy: :threads` or rely on `:auto` detection

### Empty tenant name errors

**Symptom**: `PG::SyntaxError: zero-length delimited identifier`

**Cause**: `tenant_names` proc returned empty strings or nil values

**Fix**: Fixed in v3.4.0 - empty values are now filtered automatically

## Testing Considerations

Parallel execution paths are difficult to unit test due to process isolation and connection state. The test suite verifies:

- Correct delegation between sequential/parallel paths
- Platform detection logic
- Advisory lock ENV management
- Result aggregation and error capture

Integration testing of actual parallel execution happens in CI across Linux (processes) and macOS (threads) runners.
