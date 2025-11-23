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

All elevators are Rack middleware:

```ruby
class ElevatorMiddleware
  def initialize(app, options = {})
    @app = app  # Next middleware or application
  end

  def call(env)
    # 1. Extract tenant from request
    # 2. Switch to tenant
    # 3. Call next middleware
    # 4. Ensure cleanup
  end
end
```

### Request Lifecycle with Elevator

```
HTTP Request
   ↓
[Rack Middleware Stack]
   ↓
[Elevator Middleware] ← Intercepts here
   ├─ Parse tenant from request
   ├─ Apartment::Tenant.switch(tenant)
   │     ↓
   │  [Application Code]
   │  (processes request in tenant context)
   │     ↓
   └─ Automatic cleanup (ensure block)
   ↓
HTTP Response
```

## Generic Elevator - Base Class

**Location**: `generic.rb`

### Purpose

Provides base implementation and allows custom tenant resolution via Proc or subclass.

### Implementation

```ruby
module Apartment
  module Elevators
    class Generic
      def initialize(app, processor = nil)
        @app = app
        @processor = processor  # Optional Proc for custom logic
      end

      def call(env)
        request = Rack::Request.new(env)
        tenant = parse_tenant_name(request)

        Apartment::Tenant.switch(tenant) do
          @app.call(env)
        end
      end

      def parse_tenant_name(request)
        if @processor.respond_to?(:call)
          @processor.call(request)
        else
          raise "Implement parse_tenant_name in subclass"
        end
      end
    end
  end
end
```

### Usage Patterns

**With Proc**:
```ruby
# config/application.rb
config.middleware.use Apartment::Elevators::Generic, proc { |request|
  request.headers['X-Tenant-ID']
}
```

**Via Subclass**:
```ruby
class CustomElevator < Apartment::Elevators::Generic
  def parse_tenant_name(request)
    # Custom logic
    request.subdomain.upcase
  end
end

config.middleware.use CustomElevator
```

## Subdomain Elevator

**Location**: `subdomain.rb`

### Strategy

Extract first subdomain from hostname.

### Implementation

```ruby
module Apartment
  module Elevators
    class Subdomain < Generic
      class << self
        attr_accessor :excluded_subdomains
      end

      self.excluded_subdomains = []

      def parse_tenant_name(request)
        subdomain = request.subdomain

        # Return nil for excluded subdomains (uses default tenant)
        return nil if excluded_subdomains.include?(subdomain)

        subdomain
      end

      private

      def excluded_subdomains
        self.class.excluded_subdomains
      end
    end
  end
end
```

### Configuration

```ruby
# config/application.rb
require 'apartment/elevators/subdomain'
config.middleware.use Apartment::Elevators::Subdomain

# config/initializers/apartment.rb
Apartment::Elevators::Subdomain.excluded_subdomains = ['www', 'admin', 'api']
```

### Behavior

| Request URL                  | Subdomain | Excluded? | Tenant      |
|------------------------------|-----------|-----------|-------------|
| http://acme.example.com      | acme      | No        | acme        |
| http://widgets.example.com   | widgets   | No        | widgets     |
| http://www.example.com       | www       | Yes       | (default)   |
| http://api.example.com       | api       | Yes       | (default)   |
| http://example.com           | (empty)   | N/A       | (default)   |

### How Subdomain Extraction Works

Rack's `request.subdomain` uses `ActionDispatch::Http::URL`:

```ruby
# For: http://acme.example.com
request.host          # => "acme.example.com"
request.subdomain     # => "acme"
request.domain        # => "example.com"

# For: http://api.v1.example.com
request.host          # => "api.v1.example.com"
request.subdomain     # => "api.v1" (entire subdomain chain)
# Note: FirstSubdomain elevator handles this differently
```

## FirstSubdomain Elevator

**Location**: `first_subdomain.rb`

### Strategy

Extract **first** subdomain from chain (for nested subdomains).

### Implementation

Similar to `Subdomain` but handles nested subdomains:

```ruby
def parse_tenant_name(request)
  # Split subdomain and take first part
  subdomains = request.subdomain.split('.')
  first_subdomain = subdomains.first

  return nil if excluded_subdomains.include?(first_subdomain)

  first_subdomain
end
```

### Behavior

| Request URL                      | Full Subdomain | First Subdomain | Tenant |
|----------------------------------|----------------|-----------------|--------|
| http://api.v1.example.com        | api.v1         | api             | api    |
| http://owls.birds.animals.com    | owls.birds     | owls            | owls   |
| http://www.api.example.com       | www.api        | www             | (default) if excluded |

### Configuration

```ruby
require 'apartment/elevators/first_subdomain'
config.middleware.use Apartment::Elevators::FirstSubdomain

Apartment::Elevators::FirstSubdomain.excluded_subdomains = ['www']
```

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

```ruby
def parse_tenant_name(request)
  # Get domain without TLD
  # example.com → "example"
  # www.example.com → "example"
  # api.example.com → "api"

  host = request.host
  parts = host.split('.')

  # Remove TLD (.com, .org, etc.)
  parts.pop if parts.length > 1

  # Remove 'www' if present
  parts.shift if parts.first == 'www'

  parts.first
end
```

### Behavior

| Request URL                       | Domain Parts     | Result   | Tenant   |
|-----------------------------------|------------------|----------|----------|
| http://example.com                | [example]        | example  | example  |
| http://www.example.com            | [www, example]   | example  | example  |
| http://api.example.com            | [api, example]   | api      | api      |
| http://subdomain.api.example.com  | [subdomain, api] | subdomain| subdomain|

### Configuration

```ruby
require 'apartment/elevators/domain'
config.middleware.use Apartment::Elevators::Domain
```

### Use Case

When full domain (not subdomain) identifies tenant:
- `acme-corp.com` → tenant: acme-corp
- `widgets-inc.com` → tenant: widgets-inc

## Host Elevator

**Location**: `host.rb`

### Strategy

Use **full hostname** as tenant, optionally ignoring specified first subdomains.

### Implementation

```ruby
class Host < Generic
  class << self
    attr_accessor :ignored_first_subdomains
  end

  self.ignored_first_subdomains = []

  def parse_tenant_name(request)
    host = request.host

    # Remove ignored first subdomain if present
    if ignored_first_subdomains.any?
      parts = host.split('.')
      if ignored_first_subdomains.include?(parts.first)
        parts.shift
        host = parts.join('.')
      end
    end

    host
  end

  private

  def ignored_first_subdomains
    self.class.ignored_first_subdomains
  end
end
```

### Configuration

```ruby
require 'apartment/elevators/host'
config.middleware.use Apartment::Elevators::Host

Apartment::Elevators::Host.ignored_first_subdomains = ['www', 'app']
```

### Behavior

| Request URL                  | Full Host           | Ignored? | Tenant              |
|------------------------------|---------------------|----------|---------------------|
| http://example.com           | example.com         | No       | example.com         |
| http://www.example.com       | www.example.com     | www      | example.com         |
| http://api.example.com       | api.example.com     | No       | api.example.com     |
| http://app.api.example.com   | app.api.example.com | app      | api.example.com     |

### Use Case

When each full hostname represents a different tenant:
- Tenants use custom domains: `acme-corp.com`, `widgets-inc.net`
- Internal apps: `billing.internal.company.com`, `crm.internal.company.com`

## HostHash Elevator

**Location**: `host_hash.rb`

### Strategy

Direct **mapping** from hostname to tenant name via hash.

### Implementation

```ruby
class HostHash < Generic
  def initialize(app, hash = {})
    super(app)
    @hash = hash
  end

  def parse_tenant_name(request)
    @hash[request.host]
  end
end
```

### Configuration

```ruby
require 'apartment/elevators/host_hash'

config.middleware.use Apartment::Elevators::HostHash, {
  'acme.customdomain.com'  => 'acme_corp',
  'widgets.example.io'     => 'widgets_inc',
  'startup.myapp.com'      => 'startup_tenant',
  'client-site.com'        => 'client_x'
}
```

### Behavior

| Request URL                    | Hash Lookup              | Tenant         |
|--------------------------------|--------------------------|----------------|
| http://acme.customdomain.com   | 'acme_corp'              | acme_corp      |
| http://widgets.example.io      | 'widgets_inc'            | widgets_inc    |
| http://unknown.com             | nil                      | (default)      |

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

Elevators **must** be positioned before session and authentication middleware:

```ruby
# WRONG ORDER
use ActionDispatch::Session::CookieStore  # Session loaded first
use Apartment::Elevators::Subdomain       # Tenant set second
# Problem: Session data loaded in wrong tenant context

# CORRECT ORDER
use Apartment::Elevators::Subdomain       # Tenant set first
use ActionDispatch::Session::CookieStore  # Session loaded second
# Solution: Session loaded in correct tenant context
```

### Positioning Methods

**Insert before specific middleware**:
```ruby
config.middleware.insert_before ActionDispatch::Session::CookieStore,
                                Apartment::Elevators::Subdomain
```

**Insert before authentication (Devise/Warden)**:
```ruby
config.middleware.insert_before Warden::Manager,
                                Apartment::Elevators::Subdomain
```

**Insert at beginning**:
```ruby
config.middleware.insert_at 0, Apartment::Elevators::Subdomain
```

**Insert after specific middleware**:
```ruby
config.middleware.insert_after Rack::Runtime,
                                Apartment::Elevators::Subdomain
```

### Verify Middleware Order

```ruby
# Rails console or initializer
Rails.application.middleware.each_with_index do |middleware, index|
  puts "#{index}: #{middleware.inspect}"
end

# Expected output:
# 0: Rack::Sendfile
# 1: ActionDispatch::Static
# 2: Apartment::Elevators::Subdomain  # <-- Should be EARLY
# 3: ActionDispatch::Session::CookieStore
# 4: Warden::Manager
# ...
```

## Creating Custom Elevators

### Method 1: Using Proc with Generic

```ruby
# config/application.rb
config.middleware.use Apartment::Elevators::Generic, proc { |request|
  # Custom tenant detection logic
  tenant = request.headers['X-Tenant-ID']
  tenant ||= request.session[:current_tenant]
  tenant ||= Company.find_by(subdomain: request.subdomain)&.database_name
  tenant
}
```

### Method 2: Subclassing Generic

```ruby
# app/middleware/custom_elevator.rb
class CustomElevator < Apartment::Elevators::Generic
  def parse_tenant_name(request)
    # Try multiple strategies
    detect_from_api_key(request) ||
    detect_from_subdomain(request) ||
    detect_from_session(request) ||
    'default'
  end

  private

  def detect_from_api_key(request)
    api_key = request.headers['X-API-Key']
    ApiKey.find_by(key: api_key)&.tenant_name if api_key
  end

  def detect_from_subdomain(request)
    subdomain = request.subdomain
    subdomain unless excluded_subdomains.include?(subdomain)
  end

  def detect_from_session(request)
    request.session[:tenant_name]
  end

  def excluded_subdomains
    %w[www admin api]
  end
end

# config/application.rb
config.middleware.use CustomElevator
```

### Advanced: Conditional Elevator

```ruby
class ConditionalElevator < Apartment::Elevators::Generic
  def call(env)
    request = Rack::Request.new(env)

    # Skip elevator for certain paths
    if skip_paths.any? { |path| request.path.start_with?(path) }
      return @app.call(env)
    end

    # Normal elevator behavior
    super
  end

  def skip_paths
    ['/health', '/metrics', '/system', '/webhooks']
  end

  def parse_tenant_name(request)
    request.subdomain
  end
end
```

## Error Handling

### Handling Missing Tenants

```ruby
class SafeElevator < Apartment::Elevators::Subdomain
  def call(env)
    super
  rescue Apartment::TenantNotFound => e
    Rails.logger.error "[Apartment] Tenant not found: #{e.message}"

    # Return 404 response
    [404, {'Content-Type' => 'text/html'}, ['<h1>Account Not Found</h1>']]
  end
end
```

### Custom Error Pages

```ruby
class ErrorHandlingElevator < Apartment::Elevators::Subdomain
  def call(env)
    super
  rescue Apartment::TenantNotFound
    redirect_to_not_found
  rescue Apartment::ApartmentError => e
    render_error(e)
  end

  private

  def redirect_to_not_found
    [302, {'Location' => '/account-not-found'}, []]
  end

  def render_error(error)
    [500, {'Content-Type' => 'text/plain'}, ["Error: #{error.message}"]]
  end
end
```

## Testing Elevators

### Unit Testing

```ruby
# spec/middleware/custom_elevator_spec.rb
RSpec.describe CustomElevator do
  let(:app) { ->(env) { [200, {}, ['OK']] } }
  let(:elevator) { described_class.new(app) }

  def make_request(host:, headers: {})
    env = Rack::MockRequest.env_for("http://#{host}/", headers)
    elevator.call(env)
  end

  before do
    allow(Apartment::Tenant).to receive(:switch).and_yield
  end

  it 'switches to tenant based on subdomain' do
    expect(Apartment::Tenant).to receive(:switch).with('acme')
    make_request(host: 'acme.example.com')
  end

  it 'uses default tenant for excluded subdomains' do
    expect(Apartment::Tenant).to receive(:switch).with(nil)
    make_request(host: 'www.example.com')
  end

  it 'uses API key header if present' do
    allow(ApiKey).to receive(:find_by)
      .with(key: 'secret')
      .and_return(double(tenant_name: 'widgets'))

    expect(Apartment::Tenant).to receive(:switch).with('widgets')
    make_request(host: 'example.com', headers: {'X-API-Key' => 'secret'})
  end
end
```

### Integration Testing

```ruby
# spec/requests/tenant_routing_spec.rb
RSpec.describe 'Tenant routing', type: :request do
  before do
    Apartment::Tenant.create('acme')
    Apartment::Tenant.switch('acme') { User.create!(name: 'Acme User') }
  end

  after do
    Apartment::Tenant.drop('acme')
  end

  it 'routes to correct tenant based on subdomain' do
    get 'http://acme.example.com/users'

    expect(response).to be_successful
    # Verify tenant-specific data
  end
end
```

## Performance Considerations

### Caching Tenant Lookups

If elevator does database lookups, cache results:

```ruby
class CachedElevator < Apartment::Elevators::Generic
  def parse_tenant_name(request)
    subdomain = request.subdomain

    Rails.cache.fetch("tenant:#{subdomain}", expires_in: 5.minutes) do
      Company.find_by(subdomain: subdomain)&.database_name
    end
  end
end
```

### Avoiding N+1 Queries

```ruby
# BAD: Queries on every request
proc { |request|
  Company.find_by(subdomain: request.subdomain)&.database_name
}

# GOOD: Cached lookup
proc { |request|
  tenant_map = Rails.cache.fetch('tenant_map', expires_in: 10.minutes) do
    Company.pluck(:subdomain, :database_name).to_h
  end
  tenant_map[request.subdomain]
}
```

### Monitoring Performance

```ruby
class MonitoredElevator < Apartment::Elevators::Subdomain
  def call(env)
    start = Time.current
    super
  ensure
    duration = Time.current - start

    if duration > 0.1
      Rails.logger.warn "[Apartment] Slow switch: #{duration.round(3)}s"
    end

    # Report to APM
    NewRelic::Agent.record_metric('Custom/Apartment/ElevatorTime', duration)
  end
end
```

## Common Issues

### Issue: Elevator Not Triggering

**Symptoms**: Tenant always default

**Causes**:
1. Elevator not in middleware stack
2. `parse_tenant_name` returning nil
3. Middleware positioned incorrectly

**Debug**:
```ruby
class DebugElevator < Apartment::Elevators::Subdomain
  def call(env)
    request = Rack::Request.new(env)
    tenant = parse_tenant_name(request)
    Rails.logger.debug "[Elevator] Host: #{request.host}, Tenant: #{tenant || 'nil'}"
    super
  end
end
```

### Issue: TenantNotFound Errors

**Symptoms**: 500 errors on some requests

**Causes**:
1. Tenant doesn't exist
2. Subdomain not in tenant list

**Solution**: Add error handling or tenant validation

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
