# Apartment Elevators - Middleware Design

**Key files**: `lib/apartment/elevators/*.rb`

## Purpose

Elevators are Rack middleware that automatically detect tenant from HTTP requests and establish tenant context before application code runs.

**Name metaphor**: Like elevators transport you between building floors, these middleware transport requests between tenant contexts.

## Design Decision: Why Middleware?

**Problem**: Manual tenant switching in controllers is error-prone. Easy to forget, creates boilerplate.

**Solution**: Rack middleware intercepts all requests, switches tenant automatically based on request attributes.

**Trade-off**: Adds middleware overhead (minimal) but eliminates entire class of bugs.

## Critical Positioning Requirement

**Rule**: Elevators MUST be positioned before session/authentication middleware.

**Why**: Session data is tenant-specific. Loading session before establishing tenant context causes data leakage.

**How to verify**: `Rails.application.middleware` lists order. Elevator should appear before `ActionDispatch::Session` and `Warden::Manager`.

**See**: Configuration examples in README.md

## Available Elevator Strategies

**Files**: All in `lib/apartment/elevators/`

### Subdomain Elevator

**File**: `subdomain.rb`

**Strategy**: Extract first subdomain as tenant name.

**Why PublicSuffix gem?**: Handles international TLDs correctly. `example.co.uk` has TLD `.co.uk`, not just `.uk`.

**Exclusion mechanism**: Configurable list of ignored subdomains (www, admin, api). Returns nil for excluded, which uses default tenant.

**Why class-level exclusions?**: Shared across all instances. Set once in initializer.

### Domain Elevator

**File**: `domain.rb`

**Strategy**: Use domain name (excluding www and TLD) as tenant.

**Use case**: When domain itself identifies tenant (acme.com vs widgets.com), not subdomain.

### Host Elevator

**File**: `host.rb`

**Strategy**: Use full hostname as tenant name.

**Ignored subdomains**: Optional configuration to strip www/app from beginning.

**Use case**: Custom domains where full hostname matters.

### HostHash Elevator

**File**: `host_hash.rb`

**Strategy**: Direct hash mapping from hostname to tenant name.

**Why needed?**: When hostname→tenant mapping is arbitrary or complex.

**Trade-off**: Requires explicit configuration per tenant. Not dynamic.

### Generic Elevator

**File**: `generic.rb`

**Purpose**: Base class for custom elevators. Accept Proc for inline logic or subclass for complex scenarios.

**Extension point**: Override `parse_tenant_name(request)` method.

**See**: Examples in file comments

## Design Patterns

### Why Return nil for Excluded?

Returning nil (not default_tenant name) allows Apartment core to handle fallback logic. Separation of concerns.

### Why ensure Block in call()?

Guarantees tenant cleanup even if application code raises. Prevents request bleeding into next request's tenant context.

### Why Rack::Request Object?

Standard interface. Access to host, headers, session, cookies. Database-independent.

## Request Lifecycle

**Sequence**:
1. Rack request enters application
2. Elevator middleware intercepts (positioned early)
3. Calls `parse_tenant_name(request)` - strategy determines tenant
4. Calls `Apartment::Tenant.switch(tenant) { @app.call(env) }`
5. Application processes in tenant context
6. Ensure block resets tenant after response

**Critical**: Step 6 happens even on exceptions. Why? Prevent tenant leakage.

## Performance Considerations

### Caching Tenant Lookups

If `parse_tenant_name` does database queries, consider caching:
- Subdomain→tenant mapping cached for 5-10 minutes
- Invalidate cache when tenants created/deleted

**Why needed?**: Elevator runs on EVERY request. Database query per request adds latency.

**Not implemented in v3**: Users must implement caching in custom elevators.

### Why Not Cache in Gem?

Different applications have different caching strategies (Redis, Memcached, Rails.cache). Prescribing one limits flexibility.

## Error Handling Philosophy

**Default behavior**: Exceptions propagate. TenantNotFound crashes request.

**Rationale**: Better to show error than serve wrong data or default data without user realizing.

**Alternative**: Custom elevator can rescue and return 404/redirect.

**See**: docs/adapters.md for error hierarchy

## Extension Points

### Creating Custom Elevators

**Two approaches**:

1. **Inline Proc**: For simple logic, pass Proc to Generic
2. **Subclass**: For complex logic, override `parse_tenant_name`

**When to subclass**:
- Multi-strategy fallback (header → session → subdomain)
- Database lookups with caching
- Complex validation/transformation logic

**See**: `generic.rb` for base implementation

### Common Custom Patterns

**Header-based**: API requests with `X-Tenant-ID` header
**Session-based**: Tenant selected in login flow, stored in session
**API key-based**: Database lookup from authentication token
**Hybrid**: Try multiple strategies in priority order

## Common Pitfalls

### Pitfall: Elevator After Session Middleware

**Symptom**: Wrong tenant's session data appearing

**Cause**: Session loaded before tenant switched

**Fix**: Reposition elevator before session middleware

### Pitfall: Database Queries in parse_tenant_name

**Symptom**: Slow request times, database overload

**Cause**: Query on every request without caching

**Fix**: Implement caching layer

### Pitfall: Not Handling Exclusions

**Symptom**: www.example.com creates "www" tenant, admin pages switch tenants

**Cause**: No exclusion configuration

**Fix**: Configure `excluded_subdomains`

### Pitfall: Returning Tenant Name That Doesn't Exist

**Symptom**: TenantNotFound errors

**Cause**: No validation before switching

**Fix**: Add existence check in custom elevator or handle error

## Testing Elevators

**Challenge**: Elevators are middleware, not models/controllers.

**Solution**: Use `Rack::MockRequest` to simulate requests with different hosts.

**Pattern**: Mock `Apartment::Tenant.switch` to verify correct tenant extracted.

**See**: `spec/unit/elevators/` for examples

## Integration with Background Jobs

**Important**: Elevators only affect web requests. Background jobs need separate tenant handling.

**Solution**: Job frameworks must capture and restore tenant (apartment-sidekiq gem).

**Why separate?**: Jobs aren't HTTP requests. No Rack middleware involved.

## Multi-Elevator Setup

**Possible but discouraged**: Multiple elevators in middleware stack.

**Why discouraged**: Last elevator wins. Complex, hard to debug.

**Alternative**: Single custom elevator with multi-strategy logic.

## References

- Generic base: `lib/apartment/elevators/generic.rb`
- Subdomain implementation: `lib/apartment/elevators/subdomain.rb`
- Domain implementation: `lib/apartment/elevators/domain.rb`
- Host implementations: `lib/apartment/elevators/host.rb`, `host_hash.rb`
- First subdomain: `lib/apartment/elevators/first_subdomain.rb`
- Rack middleware: https://github.com/rack/rack/wiki/Middleware
- PublicSuffix gem: https://github.com/weppos/publicsuffix-ruby
