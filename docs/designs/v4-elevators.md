# v4 Elevators Design Spec

## Overview

Phase 3 of the v4 rewrite: Rack middleware for automatic tenant detection from HTTP requests. Preserves the v3 elevator hierarchy and adds a new Header elevator for infrastructure-injected tenant identity.

**Depends on:** Phase 2 (Adapters & Tenant API), Railtie (merged in #355)

## Design Decisions

### Constructor-only configuration

v3 elevators used mutable class-level state (`Subdomain.excluded_subdomains=`, `Host.ignored_first_subdomains=`). v4 eliminates this in favor of keyword arguments passed through the constructor.

Config flows: `Apartment.configure` → `config.elevator_options` → Railtie → `middleware.use(ElevatorClass, **opts)` → constructor.

**Why:** Immutable after boot. Single configuration path. No ordering dependency between class-level setter calls and middleware insertion. Aligns with v4's frozen-config philosophy.

**Trade-off:** Users who set class-level attributes in initializers must move that config into `elevator_options`. This is a clean break (v4 is not incremental), documented in the upgrade guide.

### HostHash raises on missing host

HostHash raises `TenantNotFound` when the host isn't in the mapping. All other elevators return `nil` on no-match (falls through to default tenant).

**Why:** An explicit host→tenant mapping where the host is missing is a config error, not an expected condition. Open-ended strategies (subdomain, domain, host) can't know all valid tenants at middleware level, so nil-return is correct for them.

### Header elevator trust warning at boot

The Header elevator's `trusted: false` warning fires during the Railtie initializer (middleware insertion), not at first request.

**Why:** Boot-time warnings are visible in deploy logs, actionable before traffic arrives, and don't require a request to surface.

### Railtie passes keyword args

The Railtie passes `elevator_options` as `**opts` (keyword args), not `*opts.values` (positional). Elevator constructors accept keyword args with defaults.

**Why:** Positional args depend on hash insertion order — fragile. Keywords are explicit and self-documenting.

## Architecture

### Hierarchy

```
Apartment::Elevators::Generic        # Base Rack middleware
  ├── Subdomain                      # PublicSuffix-based subdomain extraction
  │     └── FirstSubdomain           # First segment of nested subdomains
  ├── Domain                         # Domain minus TLD, strips www
  ├── Host                           # Full hostname
  ├── HostHash                       # Hostname → tenant hash lookup
  └── Header                         # HTTP header (new)
```

All elevators live in `lib/apartment/elevators/`. Subclasses override `parse_tenant_name(request)` to extract the tenant identifier.

### Generic (base class)

```ruby
class Generic
  def initialize(app, processor = nil, **_options)
    @app = app
    @processor = processor || method(:parse_tenant_name)
  end

  def call(env)
    request = Rack::Request.new(env)
    tenant = @processor.call(request)

    if tenant
      Apartment::Tenant.switch(tenant) { @app.call(env) }
    else
      @app.call(env)
    end
  end

  def parse_tenant_name(_request)
    raise NotImplementedError, "#{self.class}#parse_tenant_name must be implemented"
  end
end
```

Block-scoped `switch` guarantees cleanup on exceptions. The `**_options` splat absorbs keyword args from `elevator_options` so Generic works when used directly with a Proc processor.

### Subdomain

```ruby
class Subdomain < Generic
  def initialize(app, excluded_subdomains: [], **_options)
    super(app)
    @excluded_subdomains = Array(excluded_subdomains).map(&:to_s).freeze
  end
end
```

Uses PublicSuffix for international TLD handling. Returns `nil` for excluded subdomains (falls through to default tenant). Instance variable replaces class-level `excluded_subdomains=`.

### FirstSubdomain

Inherits Subdomain. Takes the first segment when subdomains are nested (`tenant.staging.example.com` -> `tenant`). No additional constructor args.

**v4 fix:** v3 calls `super` twice in `parse_tenant_name` (once for nil check, once for value). v4 caches the result in a local variable.

### Domain

Extracts the first non-`www` segment of the hostname via regex (`/(?:www\.)?(?<sld>[^.]*)/`). For `a.example.bc.ca` this returns `a`, not `example`. No constructor args beyond Generic.

### Host

```ruby
class Host < Generic
  def initialize(app, ignored_first_subdomains: [], **_options)
    super(app)
    @ignored_first_subdomains = Array(ignored_first_subdomains).map(&:to_s).freeze
  end
end
```

Uses full hostname as tenant. Strips first subdomain if it appears in the ignored list (e.g., `www`).

### HostHash

```ruby
class HostHash < Generic
  def initialize(app, hash: {}, **_options)
    super(app)
    @hash = hash.freeze
  end
end
```

Raises `TenantNotFound` when host is not in the hash (explicit mapping; missing = config error). v3's optional `processor` positional arg is dropped; HostHash's tenant resolution is always via the hash lookup.

### Header (new)

```ruby
class Header < Generic
  def initialize(app, header: 'X-Tenant-Id', trusted: false, **_options)
    super(app)
    @header_name = "HTTP_#{header.upcase.tr('-', '_')}"
    @raw_header = header
  end

  def parse_tenant_name(request)
    request.get_header(@header_name)
  end
end
```

For infrastructure that injects tenant identity at the edge (CloudFront, Nginx, API gateway). The `trusted:` flag is consumed by the Railtie for a boot-time warning (see below); the elevator constructor accepts it via `**_options` splat but does not store it. The elevator behaves identically regardless of trust level; trust is an operational acknowledgment, not a runtime behavior toggle.

Missing header returns `nil` (falls through to default tenant), consistent with other elevators.

## Railtie Changes

### Middleware insertion (keyword args + Header warning)

```ruby
initializer 'apartment.middleware' do |app|
  next unless Apartment.config&.elevator

  elevator_class = Apartment::Railtie.resolve_elevator_class(Apartment.config.elevator)
  opts = Apartment.config.elevator_options || {}

  if elevator_class <= Apartment::Elevators::Header && !opts[:trusted]
    warn '[Apartment] WARNING: Header elevator with trusted: false. ' \
         'Header-based tenant resolution trusts the client to provide the correct tenant. ' \
         'Only use this when the header is injected by trusted infrastructure (CDN, reverse proxy) ' \
         'that strips client-supplied values.'
  end

  app.middleware.use(elevator_class, **opts)
end
```

The `<=` check handles subclasses of Header.

### `resolve_elevator_class` update (symbol or class)

`config.elevator` accepts both symbols (`:subdomain`) and classes (`DynamicElevator`). The resolver must handle both:

```ruby
def self.resolve_elevator_class(elevator)
  return elevator if elevator.is_a?(Class)

  class_name = "Apartment::Elevators::#{elevator.to_s.camelize}"
  require("apartment/elevators/#{elevator}")
  class_name.constantize
rescue NameError, LoadError => e
  available = Dir[File.join(__dir__, 'elevators', '*.rb')]
    .map { |f| File.basename(f, '.rb') }
    .reject { |n| n == 'generic' }
  raise(Apartment::ConfigurationError,
        "Unknown elevator '#{elevator}': #{e.message}. " \
        "Available elevators: #{available.join(', ')}")
end
```

Symbols are the canonical form for built-in elevators. Classes are for custom elevators that live outside the gem (e.g., `DynamicElevator`). The parent design spec's "always pass a class" convention is updated: symbols are resolved by the Railtie, classes pass through.

## Error Handling

Generic's `call` method does not rescue exceptions. If `Apartment::Tenant.switch` raises `TenantNotFound` (e.g., from HostHash), the exception propagates through the Rack stack. This is intentional:

- Custom elevators handle errors by wrapping `super` in their own `call` override (as DynamicElevator does with rescue -> redirect).
- The `tenant_not_found_handler` config is an adapter-level hook, not a middleware-level one.
- Generic adding rescue logic would interfere with custom error handling in subclasses.

Users who want middleware-level error handling should subclass Generic and override `call`.

## Configuration Examples

```ruby
# Subdomain with exclusions
Apartment.configure do |config|
  config.elevator = :subdomain
  config.elevator_options = { excluded_subdomains: %w[www api admin] }
end

# Header (trusted infrastructure)
Apartment.configure do |config|
  config.elevator = :header
  config.elevator_options = { header: 'X-Tenant-Id', trusted: true }
end

# HostHash (explicit mapping)
Apartment.configure do |config|
  config.elevator = :host_hash
  config.elevator_options = { hash: { 'acme.com' => 'acme', 'widgets.io' => 'widgets' } }
end

# Custom elevator class (e.g., DynamicElevator)
Apartment.configure do |config|
  config.elevator = DynamicElevator  # pass class directly, not symbol
end
```

When `elevator` is a class (not a symbol), `resolve_elevator_class` passes it through (see Railtie Changes above).

## Subclassing Contract

Custom elevators (like DynamicElevator) rely on:

1. `parse_tenant_name(request)` — overridable, returns tenant string or nil
2. `call(env)` — overridable, allows wrapping `super` with error handling
3. `subdomains(host)` / `subdomain(host)` — overridable on Subdomain/FirstSubdomain for custom host parsing

These methods remain the public extension points. No method signature changes from v3.

## Testing

### Unit tests (`spec/unit/elevators/`)

No database required. Mock `Apartment::Tenant.switch` to verify tenant resolution.

| File | Coverage |
|------|----------|
| `generic_spec.rb` | Proc processor, subclass processor, nil tenant falls through, switch called with block |
| `subdomain_spec.rb` | Subdomain extraction, excluded_subdomains filtering, IP rejection, international TLDs |
| `first_subdomain_spec.rb` | Nested subdomain extraction, nil handling |
| `domain_spec.rb` | SLD extraction, www stripping, blank host |
| `host_spec.rb` | Full hostname, ignored_first_subdomains stripping |
| `host_hash_spec.rb` | Hash lookup, raises TenantNotFound on missing host |
| `header_spec.rb` | Header extraction, Rack env key normalization, missing header returns nil |

### Integration test

Extend `spec/integration/v4/request_lifecycle_spec.rb` with a Header elevator scenario (swap middleware config, send request with tenant header, verify context).

## Files

### New
- `spec/unit/elevators/generic_spec.rb`
- `spec/unit/elevators/subdomain_spec.rb`
- `spec/unit/elevators/first_subdomain_spec.rb`
- `spec/unit/elevators/domain_spec.rb`
- `spec/unit/elevators/host_spec.rb`
- `spec/unit/elevators/host_hash_spec.rb`
- `spec/unit/elevators/header_spec.rb`
- `lib/apartment/elevators/header.rb`

### Modified
- `lib/apartment/elevators/generic.rb` — add `**_options` splat, `NotImplementedError`
- `lib/apartment/elevators/subdomain.rb` — constructor keyword args, remove class-level setters
- `lib/apartment/elevators/first_subdomain.rb` — fix double-super call
- `lib/apartment/elevators/domain.rb` — no change
- `lib/apartment/elevators/host.rb` — constructor keyword args, remove class-level setters
- `lib/apartment/elevators/host_hash.rb` — constructor keyword args
- `lib/apartment/railtie.rb` — `**opts`, Header trust warning
