# lib/apartment/elevators/ - Rack Middleware for Tenant Switching

This directory contains Rack middleware components ("elevators") that automatically detect and switch to the appropriate tenant based on incoming HTTP requests.

## Purpose

Elevators intercept incoming requests and establish tenant context **before** the application processes the request. This eliminates the need for manual tenant switching in controllers.

## Metaphor

Like a physical elevator taking you to different floors, these middleware components "elevate" your request to the correct tenant context.

## File Structure

```
elevators/
├── generic.rb           # Base elevator with customizable logic
├── subdomain.rb         # Switch based on subdomain (e.g., acme.example.com)
├── first_subdomain.rb   # Switch based on first subdomain in chain
├── domain.rb            # Switch based on domain (excluding www and TLD)
├── host.rb              # Switch based on full hostname
└── host_hash.rb         # Switch based on hostname → tenant hash mapping
```

## How Elevators Work

### Rack Middleware Pattern

All elevators are Rack middleware that intercept requests, extract tenant identifier, switch context, invoke next middleware, and ensure cleanup. See `generic.rb` for base implementation.

### Request Lifecycle with Elevator

HTTP Request → Elevator extracts tenant → Switch to tenant → Application processes → Automatic cleanup (ensure block) → HTTP Response

**See**: `Generic#call` method for middleware call pattern.

## Generic Elevator - Base Class

**Location**: `generic.rb`

### Purpose

Provides base implementation and allows custom tenant resolution via Proc or subclass.

### Implementation

Accepts optional Proc in initializer or expects `parse_tenant_name(request)` override in subclass. See `Generic` class implementation in `generic.rb`.

### Usage Patterns

**With Proc**: Pass Proc to Generic that extracts tenant from Rack::Request.

**Via Subclass**: Inherit from Generic and override `parse_tenant_name`.

**See**: `generic.rb` and README.md for usage examples.

## Subdomain Elevator

**Location**: `subdomain.rb`

### Strategy

Extract first subdomain from hostname.

### Implementation

Uses `request.subdomain` and checks against `excluded_subdomains` class attribute. Returns nil for excluded subdomains. See `Subdomain#parse_tenant_name` in `subdomain.rb`.

### Configuration

Add to middleware stack in `application.rb` and configure `excluded_subdomains` class attribute. See README.md for examples.

### Behavior

| Request URL                  | Subdomain | Excluded? | Tenant      |
|------------------------------|-----------|-----------|-------------|
| http://acme.example.com      | acme      | No        | acme        |
| http://widgets.example.com   | widgets   | No        | widgets     |
| http://www.example.com       | www       | Yes       | (default)   |
| http://api.example.com       | api       | Yes       | (default)   |
| http://example.com           | (empty)   | N/A       | (default)   |

### Why PublicSuffix Dependency?

**Rationale**: International domains require proper TLD parsing. Without PublicSuffix, `example.co.uk` would incorrectly parse `.uk` as the TLD rather than `.co.uk`, causing subdomain extraction to fail.

**Trade-off**: Adds gem dependency, but necessary for international domain support.

## FirstSubdomain Elevator

**Location**: `first_subdomain.rb`

### Strategy

Extract **first** subdomain from chain (for nested subdomains).

### Implementation

Splits subdomain on `.` and takes first part. See `FirstSubdomain#parse_tenant_name` in `first_subdomain.rb`.

### Configuration

Add to middleware stack and configure excluded subdomains. See README.md for configuration.

### Use Case

Multi-level subdomain structures where tenant is always leftmost:
- `{tenant}.api.example.com`
- `{tenant}.app.example.com`
- `{tenant}.staging.example.com`

### Note

In current v3 implementation, `Subdomain` and `FirstSubdomain` may behave identically depending on Rails version due to how `request.subdomain` works. For true nested support, test thoroughly or use custom elevator.

## Domain Elevator

**Location**: `domain.rb`

### Strategy

Use domain name (excluding 'www' and top-level domain) as tenant.

### Implementation

Extracts domain name excluding TLD and 'www' prefix. See `Domain#parse_tenant_name` in `domain.rb`.

### Configuration

Add to middleware stack. See README.md.

### Use Case

When full domain (not subdomain) identifies tenant:
- `acme-corp.com` → tenant: acme-corp
- `widgets-inc.com` → tenant: widgets-inc

## Host Elevator

**Location**: `host.rb`

### Strategy

Use **full hostname** as tenant, optionally ignoring specified first subdomains.

### Implementation

Uses full hostname as tenant, optionally ignoring specified first subdomains. See `Host#parse_tenant_name` in `host.rb`.

### Configuration

Add to middleware stack and configure `ignored_first_subdomains`. See README.md.

### Use Case

When each full hostname represents a different tenant:
- Tenants use custom domains: `acme-corp.com`, `widgets-inc.net`
- Internal apps: `billing.internal.company.com`, `crm.internal.company.com`

## HostHash Elevator

**Location**: `host_hash.rb`

### Strategy

Direct **mapping** from hostname to tenant name via hash.

### Implementation

Accepts hash mapping hostnames to tenant names. See `HostHash` implementation in `host_hash.rb`.

### Configuration

Pass hash to HostHash initializer when adding to middleware stack. See README.md for examples.

### Use Cases

- **Custom domains**: Each tenant has their own domain
- **Explicit mapping**: No parsing logic, direct control
- **Different TLDs**: .com, .io, .net, etc.

### Advantages

- ✅ Explicit control
- ✅ No parsing ambiguity
- ✅ Works with any hostname pattern

### Disadvantages

- ❌ Requires manual configuration per tenant
- ❌ Not dynamic (requires app restart for changes)
- ❌ Doesn't scale to hundreds of tenants

## Middleware Positioning

### Why Position Matters

**Critical constraint**: Elevators must run before session and authentication middleware.

**Why this matters**: Session middleware loads user data based on session ID. If session loads before tenant is established, you get the wrong tenant's session data. This creates security vulnerabilities where User A sees User B's data.

**Example failure**: Without proper positioning, `www.acme.com` might load session data from `widgets.com` tenant if session middleware runs first.

**How to verify**: Run `Rails.application.middleware` and confirm elevator appears before `ActionDispatch::Session::CookieStore` and authentication middleware like `Warden::Manager`.

## Creating Custom Elevators

### Method 1: Using Proc with Generic

Pass Proc to Generic elevator for inline tenant detection logic. See `generic.rb` and README.md.

### Method 2: Subclassing Generic

Create custom class inheriting from Generic, override `parse_tenant_name(request)`. Supports multi-strategy fallback logic. See `generic.rb` for base class.

## Error Handling

### Handling Missing Tenants

Custom elevators can rescue `Apartment::TenantNotFound` and return appropriate HTTP responses (404, redirect, etc.). See `generic.rb` for base call pattern.

### Custom Error Pages

Override `call(env)` method to wrap `super` in rescue block and handle errors. See existing elevator implementations for patterns.

## Testing Elevators

### Unit Testing

Use `Rack::MockRequest` to create test requests and mock `Apartment::Tenant.switch`. See `spec/unit/elevators/` for test patterns.

### Integration Testing

Create test tenants in before hooks, make requests to different subdomains/hosts, verify correct tenant context. See `spec/integration/` for examples.

## Performance Considerations

### Why Caching Matters for Custom Elevators

**Problem**: If your custom elevator queries the database to resolve tenant (e.g., looking up tenant by API key), you add database latency to **every request**.

**Impact**: 10-50ms per request × thousands of requests = significant overhead.

**Solution**: Cache tenant name lookups. Trade-off is stale cache if tenants are renamed, but this is rare.

### Why Preloaded Hash Maps Beat Database Queries

**Database query approach**: SELECT tenant_name FROM tenants WHERE subdomain = ? — runs on every request.

**Hash map approach**: Loaded once at boot, O(1) lookup with no I/O.

**Trade-off**: Hash maps don't update without restart, but for most applications tenant-to-subdomain mapping is stable.

### Why Monitor Elevator Performance

**Hidden cost**: Elevator runs on every request. 10ms overhead is 10% latency penalty on a 100ms request.

**Target**: Elevator should complete in <5ms. If >100ms, investigate and add logging.

## Common Issues

### Issue: Elevator Not Triggering

**Symptoms**: Tenant always default

**Causes**: Elevator not in middleware stack, `parse_tenant_name` returning nil, or incorrect middleware positioning

**Debug**: Add logging to `parse_tenant_name` to inspect extracted tenant values.

### Issue: TenantNotFound Errors

**Symptoms**: 500 errors on some requests

**Causes**: Tenant doesn't exist or subdomain not in tenant list

**Solution**: Add error handling in custom elevator or validate tenant existence before switching.

## Best Practices

1. **Position elevators early** in middleware stack
2. **Handle errors gracefully** (don't expose internals)
3. **Cache lookups** if using database queries
4. **Test thoroughly** with multiple tenants
5. **Monitor performance** (log slow switches)
6. **Document custom logic** for maintainability

## References

- Rack middleware: https://github.com/rack/rack/wiki/Middleware
- Rack::Request: https://www.rubydoc.info/github/rack/rack/Rack/Request
- Rails middleware: https://guides.rubyonrails.org/rails_on_rack.html
- Generic elevator: `generic.rb`
