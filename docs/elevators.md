# Apartment Elevators Guide

Elevators are Rack middleware components that automatically determine and switch to the appropriate tenant based on incoming HTTP requests.

## Concept

The name "elevator" is a metaphor: just as a physical elevator takes you to different floors of a building, Apartment elevators take your request to different tenant contexts.

```
HTTP Request → Elevator → Tenant Context → Application
```

## How Elevators Work

### Basic Flow

```ruby
class ElevatorMiddleware
  def initialize(app)
    @app = app
  end

  def call(env)
    # 1. Extract tenant from request
    request = Rack::Request.new(env)
    tenant = parse_tenant_name(request)

    # 2. Switch to tenant context
    Apartment::Tenant.switch(tenant) do
      # 3. Call next middleware/application
      @app.call(env)
    end
    # 4. Automatically switch back when block exits
  end
end
```

### Request Lifecycle

```
1. Request arrives: GET http://acme.example.com/orders

2. Elevator middleware intercepts request
   ├─ Creates Rack::Request object
   ├─ Calls parse_tenant_name(request)
   ├─ Returns: "acme"
   └─ Checks exclusions (if configured)

3. Apartment::Tenant.switch('acme') called
   ├─ Adapter switches to acme tenant
   └─ Stores previous tenant for rollback

4. Request processed in tenant context
   ├─ All ActiveRecord queries use acme tenant
   └─ Application logic executes normally

5. Response sent to client

6. Tenant automatically switches back
   └─ Happens in ensure block
```

## Available Elevators

### Subdomain Elevator

**Strategy**: Extract first subdomain from hostname

```ruby
# config/application.rb
require 'apartment/elevators/subdomain'

module MyApp
  class Application < Rails::Application
    config.middleware.use Apartment::Elevators::Subdomain
  end
end
```

**Configuration**:
```ruby
# config/initializers/apartment.rb
Apartment::Elevators::Subdomain.excluded_subdomains = ['www', 'admin', 'api']
```

**Behavior**:
| Request URL                   | Subdomain  | Tenant      | Notes                    |
|-------------------------------|------------|-------------|--------------------------|
| http://acme.example.com       | acme       | acme        | Switches to acme         |
| http://widgets.example.com    | widgets    | widgets     | Switches to widgets      |
| http://www.example.com        | www        | (default)   | Excluded, stays default  |
| http://api.example.com        | api        | (default)   | Excluded, stays default  |
| http://example.com            | (none)     | (default)   | No subdomain             |

**Implementation**:
```ruby
module Apartment
  module Elevators
    class Subdomain < Generic
      def parse_tenant_name(request)
        subdomain = request.subdomain

        # Check exclusions
        return nil if excluded_subdomains.include?(subdomain)

        subdomain
      end

      def self.excluded_subdomains
        @excluded_subdomains ||= []
      end

      def self.excluded_subdomains=(subdomains)
        @excluded_subdomains = subdomains
      end

      private

      def excluded_subdomains
        self.class.excluded_subdomains
      end
    end
  end
end
```

### FirstSubdomain Elevator

**Strategy**: Extract first subdomain from chain

```ruby
require 'apartment/elevators/first_subdomain'
config.middleware.use Apartment::Elevators::FirstSubdomain
```

**Configuration**:
```ruby
Apartment::Elevators::FirstSubdomain.excluded_subdomains = ['www']
```

**Behavior**:
| Request URL                           | First Subdomain | Tenant   |
|---------------------------------------|-----------------|----------|
| http://api.v1.example.com             | api             | api      |
| http://owls.birds.animals.com         | owls            | owls     |
| http://v2.api.example.com             | v2              | v2       |
| http://www.api.example.com            | www             | (default)|

**Use case**: Nested subdomains where tenant is always first.

**Note**: In current implementation (v3), `Subdomain` and `FirstSubdomain` behave identically due to how `request.subdomain` works. For true nested subdomain support, use a custom elevator.

### Domain Elevator

**Strategy**: Extract domain (excluding www and TLD)

```ruby
require 'apartment/elevators/domain'
config.middleware.use Apartment::Elevators::Domain
```

**Behavior**:
| Request URL                    | Domain     | Tenant     |
|--------------------------------|------------|------------|
| http://example.com             | example    | example    |
| http://www.example.com         | example    | example    |
| http://api.example.com         | api        | api        |
| http://subdomain.api.example.com | subdomain | subdomain |

**Implementation detail**: Ignores 'www' and TLD (.com, .org, etc.)

**Use case**: When full domain (not subdomain) identifies tenant.

### Host Elevator

**Strategy**: Use full hostname, optionally ignoring first subdomain

```ruby
require 'apartment/elevators/host'
config.middleware.use Apartment::Elevators::Host
```

**Configuration**:
```ruby
Apartment::Elevators::Host.ignored_first_subdomains = ['www', 'app']
```

**Behavior**:
| Request URL                    | Host                | Tenant (no ignore) | Tenant (www ignored) |
|--------------------------------|---------------------|-------------------|----------------------|
| http://example.com             | example.com         | example.com       | example.com          |
| http://www.example.com         | www.example.com     | www.example.com   | example.com          |
| http://api.example.com         | api.example.com     | api.example.com   | api.example.com      |
| http://www.api.example.com     | www.api.example.com | www.api.example.com | api.example.com    |

**Use case**: When you want to use the full hostname as the tenant identifier.

### HostHash Elevator

**Strategy**: Map full hostnames to tenant names

```ruby
require 'apartment/elevators/host_hash'

config.middleware.use Apartment::Elevators::HostHash, {
  'acme.customdomain.com' => 'acme_corp',
  'widgets.example.io' => 'widgets_inc',
  'startup.myapp.com' => 'startup_tenant',
  'client-site.com' => 'client_x'
}
```

**Behavior**: Direct lookup in hash.

**Use case**:
- Custom domain per tenant
- Different top-level domains
- Explicit hostname → tenant mappings

**Advantages**:
- ✅ Explicit control
- ✅ Works with any hostname
- ✅ No parsing logic needed

**Disadvantages**:
- ❌ Must configure each tenant
- ❌ Not dynamic (requires app restart for changes)

### Generic Elevator (Base Class)

**Strategy**: Custom logic via Proc or subclass

#### Using Proc

```ruby
require 'apartment/elevators/generic'

config.middleware.use Apartment::Elevators::Generic, proc { |request|
  # Custom tenant resolution
  tenant = request.headers['X-Tenant-ID']
  tenant ||= request.session[:current_tenant]
  tenant || 'default'
}
```

**Examples**:

**Header-based**:
```ruby
proc { |request|
  request.headers['X-Tenant-ID']
}
```

**Session-based**:
```ruby
proc { |request|
  request.session[:current_tenant]
}
```

**Database lookup**:
```ruby
proc { |request|
  Company.find_by(subdomain: request.subdomain)&.database_name
}
```

**Combined logic**:
```ruby
proc { |request|
  # Try API key first
  api_key = request.headers['X-API-Key']
  if api_key
    tenant = ApiKey.find_by(key: api_key)&.tenant_name
    return tenant if tenant
  end

  # Fall back to subdomain
  subdomain = request.subdomain
  return subdomain unless %w[www api admin].include?(subdomain)

  # Default tenant
  'public'
}
```

#### Using Subclass

```ruby
# app/middleware/custom_elevator.rb
class CustomElevator < Apartment::Elevators::Generic
  def parse_tenant_name(request)
    # request is a Rack::Request object
    # Return tenant name or nil for default

    # Example: Multi-factor tenant detection
    tenant = detect_from_api_key(request)
    tenant ||= detect_from_subdomain(request)
    tenant ||= detect_from_session(request)
    tenant
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

## Middleware Positioning

**Critical**: Elevator must be positioned correctly in the middleware stack.

### Why Position Matters

```ruby
# WRONG ORDER (elevator after session)
use ActionDispatch::Session::CookieStore
use Apartment::Elevators::Subdomain
# Problem: Session loaded before tenant set → wrong data

# CORRECT ORDER (elevator before session)
use Apartment::Elevators::Subdomain
use ActionDispatch::Session::CookieStore
# Solution: Tenant set before session loaded → correct data
```

### Positioning Examples

**Before session middleware**:
```ruby
config.middleware.insert_before ActionDispatch::Session::CookieStore,
                                Apartment::Elevators::Subdomain
```

**Before authentication (Devise/Warden)**:
```ruby
config.middleware.insert_before Warden::Manager,
                                Apartment::Elevators::Subdomain
```

**At specific position**:
```ruby
config.middleware.insert_at 0, Apartment::Elevators::Subdomain  # First
```

**After specific middleware**:
```ruby
config.middleware.insert_after Rack::Runtime,
                                Apartment::Elevators::Subdomain
```

### Verify Middleware Order

```ruby
# In Rails console or initializer
Rails.application.middleware.each_with_index do |middleware, index|
  puts "#{index}: #{middleware.inspect}"
end

# Look for output like:
# 0: Rack::Sendfile
# 1: ActionDispatch::Static
# 2: Apartment::Elevators::Subdomain  # Should be EARLY
# 3: ActionDispatch::Session::CookieStore
# 4: Warden::Manager
# ...
```

## Advanced Patterns

### Multi-Elevator Setup

You can use multiple elevators for different routes:

```ruby
# config/application.rb
# Subdomain elevator for main app
config.middleware.use Apartment::Elevators::Subdomain

# API key elevator for API routes
config.middleware.use Apartment::Elevators::Generic, proc { |request|
  if request.path.start_with?('/api/')
    request.headers['X-Tenant-ID']
  else
    nil  # Let Subdomain elevator handle
  end
}
```

**Warning**: Last elevator wins, so order matters.

### Conditional Elevator

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
    ['/health', '/metrics', '/system']
  end
end
```

### Tenant Detection with Fallback

```ruby
class FallbackElevator < Apartment::Elevators::Generic
  def parse_tenant_name(request)
    # Try multiple strategies
    tenant = from_header(request)
    tenant ||= from_subdomain(request)
    tenant ||= from_cookie(request)
    tenant ||= 'default'

    # Validate tenant exists
    validate_tenant(tenant)
  end

  private

  def from_header(request)
    request.headers['X-Tenant-Name']
  end

  def from_subdomain(request)
    subdomain = request.subdomain
    subdomain unless %w[www api].include?(subdomain)
  end

  def from_cookie(request)
    request.cookies['tenant_name']
  end

  def validate_tenant(tenant)
    if Apartment.tenant_names.include?(tenant)
      tenant
    else
      Rails.logger.warn "Invalid tenant: #{tenant}"
      'default'
    end
  end
end
```

### Logging Elevator

```ruby
class LoggingElevator < Apartment::Elevators::Subdomain
  def call(env)
    request = Rack::Request.new(env)
    tenant = parse_tenant_name(request)

    Rails.logger.info "[Apartment] Request from #{request.host} → tenant: #{tenant || 'default'}"

    start_time = Time.current
    super
  ensure
    duration = Time.current - start_time
    Rails.logger.info "[Apartment] Request completed in #{duration.round(3)}s"
  end
end
```

## Error Handling

### Handling Missing Tenants

```ruby
class SafeElevator < Apartment::Elevators::Generic
  def call(env)
    super
  rescue Apartment::TenantNotFound => e
    # Log error
    Rails.logger.error "[Apartment] Tenant not found: #{e.message}"

    # Render error page
    [404, {'Content-Type' => 'text/html'}, ['<h1>Account Not Found</h1>']]
  end
end
```

### Custom Error Pages

```ruby
class CustomErrorElevator < Apartment::Elevators::Subdomain
  def call(env)
    super
  rescue Apartment::TenantNotFound
    redirect_to_not_found(env)
  rescue Apartment::ApartmentError => e
    render_error(env, e)
  end

  private

  def redirect_to_not_found(env)
    [302, {'Location' => '/account-not-found'}, []]
  end

  def render_error(env, error)
    [500, {'Content-Type' => 'text/plain'}, ["Error: #{error.message}"]]
  end
end
```

## Testing Elevators

### Unit Testing Custom Elevator

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

  it 'uses API key header if present' do
    allow(ApiKey).to receive(:find_by).with(key: 'secret123')
                                      .and_return(double(tenant_name: 'widgets'))

    expect(Apartment::Tenant).to receive(:switch).with('widgets')
    make_request(host: 'example.com', headers: {'X-API-Key' => 'secret123'})
  end

  it 'falls back to default for excluded subdomains' do
    expect(Apartment::Tenant).to receive(:switch).with(nil)
    make_request(host: 'www.example.com')
  end
end
```

### Integration Testing with Elevators

```ruby
# spec/requests/tenant_switching_spec.rb
RSpec.describe 'Tenant switching', type: :request do
  before do
    Apartment::Tenant.create('acme') unless Apartment.tenant_names.include?('acme')
    Apartment::Tenant.create('widgets') unless Apartment.tenant_names.include?('widgets')
  end

  after do
    Apartment::Tenant.drop('acme')
    Apartment::Tenant.drop('widgets')
  end

  it 'switches tenant based on subdomain' do
    # Create tenant-specific data
    Apartment::Tenant.switch('acme') do
      User.create!(name: 'Acme User')
    end

    # Request with subdomain
    get 'http://acme.example.com/users'

    expect(response).to be_successful
    # Verify correct tenant data returned
  end
end
```

## Performance Considerations

### Caching Tenant Lookups

If `parse_tenant_name` does database lookups, cache results:

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

# GOOD: Use cached tenant list
proc { |request|
  subdomain = request.subdomain
  tenant_map = Rails.cache.fetch('tenant_subdomain_map', expires_in: 10.minutes) do
    Company.pluck(:subdomain, :database_name).to_h
  end
  tenant_map[subdomain]
}
```

### Monitoring Elevator Performance

```ruby
class MonitoredElevator < Apartment::Elevators::Subdomain
  def call(env)
    start = Time.current

    super
  ensure
    duration = Time.current - start

    # Log slow tenant switches
    if duration > 0.1
      Rails.logger.warn "[Apartment] Slow tenant switch: #{duration.round(3)}s"
    end

    # Report to APM
    NewRelic::Agent.record_metric('Custom/Apartment/SwitchTime', duration)
  end
end
```

## Common Issues

### Issue: Elevator Not Triggering

**Symptoms**: Tenant always stays default

**Causes**:
1. Elevator not in middleware stack
2. Elevator positioned after session/auth middleware
3. `parse_tenant_name` returning nil
4. Subdomain not being extracted correctly

**Solution**:
```ruby
# Verify middleware stack
Rails.application.middleware.each { |m| puts m.inspect }

# Add debug logging
class DebugElevator < Apartment::Elevators::Subdomain
  def call(env)
    request = Rack::Request.new(env)
    tenant = parse_tenant_name(request)
    Rails.logger.debug "[Elevator] Host: #{request.host}, Tenant: #{tenant || 'nil'}"
    super
  end
end
```

### Issue: Wrong Tenant Context

**Symptoms**: Data from wrong tenant appearing

**Causes**:
1. Elevator after session loading
2. Cached data from previous request
3. Background jobs not preserving tenant
4. Manual `switch!` without cleanup

**Solution**:
```ruby
# Fix middleware order
config.middleware.insert_before ActionDispatch::Session::CookieStore,
                                Apartment::Elevators::Subdomain

# Clear query cache
Apartment.connection.clear_query_cache
```

### Issue: TenantNotFound Errors

**Symptoms**: 500 errors when accessing certain subdomains

**Causes**:
1. Tenant doesn't exist
2. Tenant name mismatch
3. Excluded subdomain not configured

**Solution**:
```ruby
# Validate tenants exist
Apartment.tenant_names  # Check list

# Add error handling
class SafeElevator < Apartment::Elevators::Subdomain
  def call(env)
    super
  rescue Apartment::TenantNotFound
    [404, {'Content-Type' => 'text/plain'}, ['Tenant not found']]
  end
end
```

## Best Practices

1. **Always use block-based switching** in elevators
2. **Position elevators early** in middleware stack
3. **Handle errors gracefully** (don't expose internals)
4. **Cache tenant lookups** if using database queries
5. **Monitor performance** (log slow switches)
6. **Test with multiple tenants** (integration tests)
7. **Document custom logic** (explain tenant resolution)

## References

- Rack middleware: https://github.com/rack/rack/wiki/Middleware
- Request object: https://www.rubydoc.info/github/rack/rack/Rack/Request
- Rails middleware: https://guides.rubyonrails.org/rails_on_rack.html
