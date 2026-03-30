# Phase 3: Elevators Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rewrite all elevator middleware for v4, add new Header elevator, wire keyword-arg config through the Railtie.

**Architecture:** Elevators are Rack middleware that detect tenant from HTTP requests and call `Apartment::Tenant.switch(tenant) { @app.call(env) }`. Constructor-only configuration via `elevator_options` keyword args; no class-level mutable state. Generic base class; six subclasses (Subdomain, FirstSubdomain, Domain, Host, HostHash, Header).

**Tech Stack:** Ruby, Rack, PublicSuffix gem (for Subdomain/FirstSubdomain), RSpec

**Spec:** `docs/designs/v4-elevators.md`

---

## File Map

### Create
| File | Responsibility |
|------|---------------|
| `lib/apartment/elevators/header.rb` | Header-based tenant resolution (new elevator) |
| `spec/unit/elevators/generic_spec.rb` | Generic base class tests |
| `spec/unit/elevators/subdomain_spec.rb` | Subdomain elevator tests |
| `spec/unit/elevators/first_subdomain_spec.rb` | FirstSubdomain elevator tests |
| `spec/unit/elevators/domain_spec.rb` | Domain elevator tests |
| `spec/unit/elevators/host_spec.rb` | Host elevator tests |
| `spec/unit/elevators/host_hash_spec.rb` | HostHash elevator tests |
| `spec/unit/elevators/header_spec.rb` | Header elevator tests |

### Modify
| File | Change |
|------|--------|
| `lib/apartment/elevators/generic.rb` | Add `**_options` splat to constructor, `NotImplementedError` in `parse_tenant_name` |
| `lib/apartment/elevators/subdomain.rb` | Constructor keyword args, remove class-level setters |
| `lib/apartment/elevators/first_subdomain.rb` | Fix double-`super` call |
| `lib/apartment/elevators/host.rb` | Constructor keyword args, remove class-level setters |
| `lib/apartment/elevators/host_hash.rb` | Constructor keyword args (`hash:`), drop positional `processor` |
| `lib/apartment/elevators/domain.rb` | No code changes (inherits Generic's new constructor); verify tests pass |
| `lib/apartment/railtie.rb` | `**opts` (not `*values`), `resolve_elevator_class` handles classes, Header trust warning |
| `lib/apartment.rb` | Remove Zeitwerk ignore for `elevators/` directory |

---

## Task 1: Remove Zeitwerk ignore + update Generic base class

**Files:**
- Modify: `lib/apartment.rb:18-19`
- Modify: `lib/apartment/elevators/generic.rb`
- Create: `spec/unit/elevators/generic_spec.rb`

- [ ] **Step 1: Write failing tests for Generic**

Create `spec/unit/elevators/generic_spec.rb`:

```ruby
# frozen_string_literal: true

require 'spec_helper'
require 'rack'
require 'apartment/elevators/generic'

RSpec.describe(Apartment::Elevators::Generic) do
  let(:inner_app) { ->(env) { [200, { 'Content-Type' => 'text/plain' }, [env['apartment.tenant'] || 'default']] } }

  describe '#call' do
    it 'switches tenant when processor returns a tenant name' do
      elevator = described_class.new(inner_app, ->(_req) { 'acme' })

      expect(Apartment::Tenant).to(receive(:switch).with('acme').and_yield)

      elevator.call(Rack::MockRequest.env_for('http://example.com'))
    end

    it 'does not switch when processor returns nil' do
      elevator = described_class.new(inner_app, ->(_req) { nil })

      expect(Apartment::Tenant).not_to(receive(:switch))

      elevator.call(Rack::MockRequest.env_for('http://example.com'))
    end

    it 'calls the inner app' do
      elevator = described_class.new(inner_app, ->(_req) { nil })

      status, = elevator.call(Rack::MockRequest.env_for('http://example.com'))
      expect(status).to(eq(200))
    end

    it 'uses parse_tenant_name when no processor provided' do
      subclass = Class.new(described_class) do
        def parse_tenant_name(_request)
          'from_subclass'
        end
      end

      elevator = subclass.new(inner_app)
      expect(Apartment::Tenant).to(receive(:switch).with('from_subclass').and_yield)

      elevator.call(Rack::MockRequest.env_for('http://example.com'))
    end

    it 'absorbs keyword args without error' do
      expect { described_class.new(inner_app, nil, some_option: 'value') }.not_to(raise_error)
    end
  end

  describe '#parse_tenant_name' do
    it 'raises NotImplementedError by default' do
      elevator = described_class.new(inner_app)
      request = Rack::Request.new(Rack::MockRequest.env_for('http://example.com'))

      expect { elevator.parse_tenant_name(request) }
        .to(raise_error(NotImplementedError, /parse_tenant_name must be implemented/))
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/unit/elevators/generic_spec.rb`
Expected: Failures (file doesn't match expected interface yet)

- [ ] **Step 3: Update Generic implementation**

Replace `lib/apartment/elevators/generic.rb`:

```ruby
# frozen_string_literal: true

require 'rack/request'
require 'apartment/tenant'

module Apartment
  module Elevators
    # Base elevator — Rack middleware that detects tenant from request and switches context.
    # Subclasses override parse_tenant_name(request). Custom logic via Proc in constructor.
    class Generic
      def initialize(app, processor = nil, **_options)
        @app = app
        @processor = processor || method(:parse_tenant_name)
      end

      def call(env)
        request = Rack::Request.new(env)
        database = @processor.call(request)

        if database
          Apartment::Tenant.switch(database) { @app.call(env) }
        else
          @app.call(env)
        end
      end

      def parse_tenant_name(_request)
        raise(NotImplementedError, "#{self.class}#parse_tenant_name must be implemented")
      end
    end
  end
end
```

- [ ] **Step 4: Remove Zeitwerk ignore for elevators**

In `lib/apartment.rb`, remove lines 18-19:
```ruby
# v3 elevators — will be replaced in Phase 3.
loader.ignore("#{__dir__}/apartment/elevators")
```

- [ ] **Step 5: Run Generic tests to verify they pass**

Run: `bundle exec rspec spec/unit/elevators/generic_spec.rb`
Expected: All pass

- [ ] **Step 6: Run full unit suite to verify Zeitwerk ignore removal is safe**

Run: `bundle exec rspec spec/unit/`
Expected: All pass (other elevator files are valid Ruby; Zeitwerk can load them)

- [ ] **Step 7: Commit**

```bash
git add lib/apartment.rb lib/apartment/elevators/generic.rb spec/unit/elevators/generic_spec.rb
git commit -m "v4 Generic elevator: keyword args splat, NotImplementedError default"
```

---

## Task 2: Subdomain elevator

**Files:**
- Modify: `lib/apartment/elevators/subdomain.rb`
- Create: `spec/unit/elevators/subdomain_spec.rb`

- [ ] **Step 1: Write failing tests for Subdomain**

Create `spec/unit/elevators/subdomain_spec.rb`:

```ruby
# frozen_string_literal: true

require 'spec_helper'
require 'rack'
require 'apartment/elevators/subdomain'

RSpec.describe(Apartment::Elevators::Subdomain) do
  let(:inner_app) { ->(env) { [200, {}, ['ok']] } }

  def env_for(host)
    Rack::MockRequest.env_for("http://#{host}/")
  end

  def request_for(host)
    Rack::Request.new(env_for(host))
  end

  describe '#parse_tenant_name' do
    it 'extracts subdomain from host' do
      elevator = described_class.new(inner_app)
      expect(elevator.parse_tenant_name(request_for('acme.example.com'))).to(eq('acme'))
    end

    it 'returns nil for excluded subdomains' do
      elevator = described_class.new(inner_app, excluded_subdomains: %w[www api])
      expect(elevator.parse_tenant_name(request_for('www.example.com'))).to(be_nil)
    end

    it 'returns nil for bare domain (no subdomain)' do
      elevator = described_class.new(inner_app)
      expect(elevator.parse_tenant_name(request_for('example.com'))).to(be_nil)
    end

    it 'returns nil for IP addresses' do
      elevator = described_class.new(inner_app)
      expect(elevator.parse_tenant_name(request_for('127.0.0.1'))).to(be_nil)
    end

    it 'handles international TLDs correctly' do
      elevator = described_class.new(inner_app)
      expect(elevator.parse_tenant_name(request_for('acme.example.co.uk'))).to(eq('acme'))
    end

    it 'coerces excluded_subdomains to strings' do
      elevator = described_class.new(inner_app, excluded_subdomains: [:www])
      expect(elevator.parse_tenant_name(request_for('www.example.com'))).to(be_nil)
    end

    it 'freezes excluded_subdomains' do
      elevator = described_class.new(inner_app, excluded_subdomains: %w[www])
      expect(elevator.instance_variable_get(:@excluded_subdomains)).to(be_frozen)
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/unit/elevators/subdomain_spec.rb`
Expected: Failures (constructor doesn't accept keyword args)

- [ ] **Step 3: Update Subdomain implementation**

Replace `lib/apartment/elevators/subdomain.rb`:

```ruby
# frozen_string_literal: true

require 'apartment/elevators/generic'
require 'public_suffix'

module Apartment
  module Elevators
    # Tenant from subdomain. Uses PublicSuffix for international TLD handling.
    class Subdomain < Generic
      def initialize(app, excluded_subdomains: [], **_options)
        super(app)
        @excluded_subdomains = Array(excluded_subdomains).map(&:to_s).freeze
      end

      def parse_tenant_name(request)
        request_subdomain = subdomain(request.host)

        return nil if request_subdomain.blank?
        return nil if @excluded_subdomains.include?(request_subdomain)

        request_subdomain
      end

      protected

      def subdomain(host)
        subdomains(host).first
      end

      def subdomains(host)
        host_valid?(host) ? parse_host(host) : []
      end

      def host_valid?(host)
        !ip_host?(host) && domain_valid?(host)
      end

      def ip_host?(host)
        !/^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$/.match(host).nil?
      end

      def domain_valid?(host)
        PublicSuffix.valid?(host, ignore_private: true)
      end

      def parse_host(host)
        (PublicSuffix.parse(host, ignore_private: true).trd || '').split('.')
      end
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/unit/elevators/subdomain_spec.rb`
Expected: All pass

- [ ] **Step 5: Commit**

```bash
git add lib/apartment/elevators/subdomain.rb spec/unit/elevators/subdomain_spec.rb
git commit -m "v4 Subdomain elevator: constructor keyword args, remove class-level setters"
```

---

## Task 3: FirstSubdomain elevator

**Note:** With the current Subdomain implementation (`subdomain` returns `subdomains(host).first`), FirstSubdomain is functionally equivalent to Subdomain for most inputs. The `.split('.').first` in FirstSubdomain is a no-op because `subdomain` already returns the first segment. We keep the class for backward compatibility (existing subclasses like DynamicElevator inherit from it), and the double-super fix is still worth doing for correctness.

**Files:**
- Modify: `lib/apartment/elevators/first_subdomain.rb`
- Create: `spec/unit/elevators/first_subdomain_spec.rb`

- [ ] **Step 1: Write failing tests for FirstSubdomain**

Create `spec/unit/elevators/first_subdomain_spec.rb`:

```ruby
# frozen_string_literal: true

require 'spec_helper'
require 'rack'
require 'apartment/elevators/first_subdomain'

RSpec.describe(Apartment::Elevators::FirstSubdomain) do
  let(:inner_app) { ->(env) { [200, {}, ['ok']] } }

  def request_for(host)
    Rack::Request.new(Rack::MockRequest.env_for("http://#{host}/"))
  end

  describe '#parse_tenant_name' do
    it 'extracts the first subdomain segment' do
      elevator = described_class.new(inner_app)
      expect(elevator.parse_tenant_name(request_for('acme.staging.example.com'))).to(eq('acme'))
    end

    it 'works with a single subdomain' do
      elevator = described_class.new(inner_app)
      expect(elevator.parse_tenant_name(request_for('acme.example.com'))).to(eq('acme'))
    end

    it 'returns nil when no subdomain' do
      elevator = described_class.new(inner_app)
      expect(elevator.parse_tenant_name(request_for('example.com'))).to(be_nil)
    end

    it 'respects excluded_subdomains from Subdomain' do
      elevator = described_class.new(inner_app, excluded_subdomains: %w[www])
      expect(elevator.parse_tenant_name(request_for('www.example.com'))).to(be_nil)
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/unit/elevators/first_subdomain_spec.rb`
Expected: Failures (double-super issue or constructor mismatch)

- [ ] **Step 3: Update FirstSubdomain implementation**

Replace `lib/apartment/elevators/first_subdomain.rb`:

```ruby
# frozen_string_literal: true

require 'apartment/elevators/subdomain'

module Apartment
  module Elevators
    # Tenant from the first segment of nested subdomains.
    # acme.staging.example.com -> acme
    class FirstSubdomain < Subdomain
      def parse_tenant_name(request)
        tenant = super
        return nil if tenant.nil?

        tenant.split('.').first
      end
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/unit/elevators/first_subdomain_spec.rb`
Expected: All pass

- [ ] **Step 5: Commit**

```bash
git add lib/apartment/elevators/first_subdomain.rb spec/unit/elevators/first_subdomain_spec.rb
git commit -m "v4 FirstSubdomain elevator: fix double-super call"
```

---

## Task 4: Domain elevator

**Files:**
- Modify: `lib/apartment/elevators/domain.rb` (no changes needed, but verify)
- Create: `spec/unit/elevators/domain_spec.rb`

- [ ] **Step 1: Write tests for Domain**

Create `spec/unit/elevators/domain_spec.rb`:

```ruby
# frozen_string_literal: true

require 'spec_helper'
require 'rack'
require 'apartment/elevators/domain'

RSpec.describe(Apartment::Elevators::Domain) do
  let(:inner_app) { ->(env) { [200, {}, ['ok']] } }

  def request_for(host)
    Rack::Request.new(Rack::MockRequest.env_for("http://#{host}/"))
  end

  describe '#parse_tenant_name' do
    it 'extracts domain name from simple host' do
      elevator = described_class.new(inner_app)
      expect(elevator.parse_tenant_name(request_for('example.com'))).to(eq('example'))
    end

    it 'strips www prefix' do
      elevator = described_class.new(inner_app)
      expect(elevator.parse_tenant_name(request_for('www.example.com'))).to(eq('example'))
    end

    it 'extracts first non-www segment with subdomains' do
      elevator = described_class.new(inner_app)
      expect(elevator.parse_tenant_name(request_for('a.example.bc.ca'))).to(eq('a'))
    end

    it 'strips www even with complex TLD' do
      elevator = described_class.new(inner_app)
      expect(elevator.parse_tenant_name(request_for('www.example.bc.ca'))).to(eq('example'))
    end

    it 'returns nil for blank host' do
      elevator = described_class.new(inner_app)
      request = Rack::Request.new(Rack::MockRequest.env_for('/'))
      allow(request).to(receive(:host).and_return(''))
      expect(elevator.parse_tenant_name(request)).to(be_nil)
    end
  end
end
```

- [ ] **Step 2: Run tests**

Run: `bundle exec rspec spec/unit/elevators/domain_spec.rb`
Expected: All pass (Domain implementation is unchanged from v3)

- [ ] **Step 3: Commit**

```bash
git add lib/apartment/elevators/domain.rb spec/unit/elevators/domain_spec.rb
git commit -m "v4 Domain elevator: add unit tests"
```

---

## Task 5: Host elevator

**Files:**
- Modify: `lib/apartment/elevators/host.rb`
- Create: `spec/unit/elevators/host_spec.rb`

- [ ] **Step 1: Write failing tests for Host**

Create `spec/unit/elevators/host_spec.rb`:

```ruby
# frozen_string_literal: true

require 'spec_helper'
require 'rack'
require 'apartment/elevators/host'

RSpec.describe(Apartment::Elevators::Host) do
  let(:inner_app) { ->(env) { [200, {}, ['ok']] } }

  def request_for(host)
    Rack::Request.new(Rack::MockRequest.env_for("http://#{host}/"))
  end

  describe '#parse_tenant_name' do
    it 'returns the full hostname' do
      elevator = described_class.new(inner_app)
      expect(elevator.parse_tenant_name(request_for('acme.example.com'))).to(eq('acme.example.com'))
    end

    it 'strips ignored first subdomains' do
      elevator = described_class.new(inner_app, ignored_first_subdomains: %w[www])
      expect(elevator.parse_tenant_name(request_for('www.example.com'))).to(eq('example.com'))
    end

    it 'does not strip non-ignored subdomains' do
      elevator = described_class.new(inner_app, ignored_first_subdomains: %w[www])
      expect(elevator.parse_tenant_name(request_for('acme.example.com'))).to(eq('acme.example.com'))
    end

    it 'returns nil for blank host' do
      elevator = described_class.new(inner_app)
      request = Rack::Request.new(Rack::MockRequest.env_for('/'))
      allow(request).to(receive(:host).and_return(''))
      expect(elevator.parse_tenant_name(request)).to(be_nil)
    end

    it 'coerces ignored_first_subdomains to strings' do
      elevator = described_class.new(inner_app, ignored_first_subdomains: [:www])
      expect(elevator.parse_tenant_name(request_for('www.example.com'))).to(eq('example.com'))
    end

    it 'freezes ignored_first_subdomains' do
      elevator = described_class.new(inner_app, ignored_first_subdomains: %w[www])
      expect(elevator.instance_variable_get(:@ignored_first_subdomains)).to(be_frozen)
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/unit/elevators/host_spec.rb`
Expected: Failures (constructor doesn't accept keyword args)

- [ ] **Step 3: Update Host implementation**

Replace `lib/apartment/elevators/host.rb`:

```ruby
# frozen_string_literal: true

require 'apartment/elevators/generic'

module Apartment
  module Elevators
    # Tenant from full hostname. Optionally strips ignored first subdomains (e.g., www).
    class Host < Generic
      def initialize(app, ignored_first_subdomains: [], **_options)
        super(app)
        @ignored_first_subdomains = Array(ignored_first_subdomains).map(&:to_s).freeze
      end

      def parse_tenant_name(request)
        return nil if request.host.blank?

        parts = request.host.split('.')
        @ignored_first_subdomains.include?(parts[0]) ? parts.drop(1).join('.') : request.host
      end
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/unit/elevators/host_spec.rb`
Expected: All pass

- [ ] **Step 5: Commit**

```bash
git add lib/apartment/elevators/host.rb spec/unit/elevators/host_spec.rb
git commit -m "v4 Host elevator: constructor keyword args, remove class-level setters"
```

---

## Task 6: HostHash elevator

**Files:**
- Modify: `lib/apartment/elevators/host_hash.rb`
- Create: `spec/unit/elevators/host_hash_spec.rb`

- [ ] **Step 1: Write failing tests for HostHash**

Create `spec/unit/elevators/host_hash_spec.rb`:

```ruby
# frozen_string_literal: true

require 'spec_helper'
require 'rack'
require 'apartment/elevators/host_hash'

RSpec.describe(Apartment::Elevators::HostHash) do
  let(:inner_app) { ->(env) { [200, {}, ['ok']] } }
  let(:mapping) { { 'acme.com' => 'acme', 'widgets.io' => 'widgets' } }

  def request_for(host)
    Rack::Request.new(Rack::MockRequest.env_for("http://#{host}/"))
  end

  describe '#parse_tenant_name' do
    it 'returns the mapped tenant for a known host' do
      elevator = described_class.new(inner_app, hash: mapping)
      expect(elevator.parse_tenant_name(request_for('acme.com'))).to(eq('acme'))
    end

    it 'raises TenantNotFound for an unknown host' do
      elevator = described_class.new(inner_app, hash: mapping)
      expect { elevator.parse_tenant_name(request_for('unknown.com')) }
        .to(raise_error(Apartment::TenantNotFound, /unknown\.com/))
    end

    it 'sets the tenant attribute on TenantNotFound' do
      elevator = described_class.new(inner_app, hash: mapping)
      expect { elevator.parse_tenant_name(request_for('unknown.com')) }
        .to(raise_error { |e| expect(e.tenant).to(eq('unknown.com')) })
    end

    it 'freezes the hash' do
      elevator = described_class.new(inner_app, hash: mapping)
      expect(elevator.instance_variable_get(:@hash)).to(be_frozen)
    end

    it 'defaults to empty hash' do
      elevator = described_class.new(inner_app)
      expect { elevator.parse_tenant_name(request_for('anything.com')) }
        .to(raise_error(Apartment::TenantNotFound))
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/unit/elevators/host_hash_spec.rb`
Expected: Failures (constructor uses positional args)

- [ ] **Step 3: Update HostHash implementation**

Replace `lib/apartment/elevators/host_hash.rb`:

```ruby
# frozen_string_literal: true

require 'apartment/elevators/generic'

module Apartment
  module Elevators
    # Tenant from hostname -> tenant hash mapping.
    # Raises TenantNotFound when host is not in the hash (explicit mapping; missing = config error).
    class HostHash < Generic
      def initialize(app, hash: {}, **_options)
        super(app)
        @hash = hash.freeze
      end

      def parse_tenant_name(request)
        raise(TenantNotFound, request.host) unless @hash.key?(request.host)

        @hash[request.host]
      end
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/unit/elevators/host_hash_spec.rb`
Expected: All pass

- [ ] **Step 5: Commit**

```bash
git add lib/apartment/elevators/host_hash.rb spec/unit/elevators/host_hash_spec.rb
git commit -m "v4 HostHash elevator: keyword args, drop positional processor"
```

---

## Task 7: Header elevator (new)

**Files:**
- Create: `lib/apartment/elevators/header.rb`
- Create: `spec/unit/elevators/header_spec.rb`

- [ ] **Step 1: Write failing tests for Header**

Create `spec/unit/elevators/header_spec.rb`:

```ruby
# frozen_string_literal: true

require 'spec_helper'
require 'rack'
require 'apartment/elevators/header'

RSpec.describe(Apartment::Elevators::Header) do
  let(:inner_app) { ->(env) { [200, {}, ['ok']] } }

  def env_with_header(header_name, value)
    rack_key = "HTTP_#{header_name.upcase.tr('-', '_')}"
    Rack::MockRequest.env_for('http://example.com/', rack_key => value)
  end

  describe '#parse_tenant_name' do
    it 'extracts tenant from the default X-Tenant-Id header' do
      elevator = described_class.new(inner_app)
      request = Rack::Request.new(env_with_header('X-Tenant-Id', 'acme'))
      expect(elevator.parse_tenant_name(request)).to(eq('acme'))
    end

    it 'extracts tenant from a custom header' do
      elevator = described_class.new(inner_app, header: 'X-CampusESP-Tenant')
      request = Rack::Request.new(env_with_header('X-CampusESP-Tenant', 'widgets'))
      expect(elevator.parse_tenant_name(request)).to(eq('widgets'))
    end

    it 'returns nil when header is missing' do
      elevator = described_class.new(inner_app)
      request = Rack::Request.new(Rack::MockRequest.env_for('http://example.com/'))
      expect(elevator.parse_tenant_name(request)).to(be_nil)
    end

    it 'handles header names with mixed case' do
      elevator = described_class.new(inner_app, header: 'x-tenant-id')
      request = Rack::Request.new(env_with_header('X-Tenant-Id', 'acme'))
      expect(elevator.parse_tenant_name(request)).to(eq('acme'))
    end

    it 'accepts trusted: without affecting behavior' do
      elevator = described_class.new(inner_app, trusted: true)
      request = Rack::Request.new(env_with_header('X-Tenant-Id', 'acme'))
      expect(elevator.parse_tenant_name(request)).to(eq('acme'))
    end
  end

  describe '#call' do
    it 'switches tenant when header is present' do
      elevator = described_class.new(inner_app)
      expect(Apartment::Tenant).to(receive(:switch).with('acme').and_yield)

      elevator.call(env_with_header('X-Tenant-Id', 'acme'))
    end

    it 'does not switch when header is absent' do
      elevator = described_class.new(inner_app)
      expect(Apartment::Tenant).not_to(receive(:switch))

      elevator.call(Rack::MockRequest.env_for('http://example.com/'))
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/unit/elevators/header_spec.rb`
Expected: LoadError (file doesn't exist yet)

- [ ] **Step 3: Implement Header elevator**

Create `lib/apartment/elevators/header.rb`:

```ruby
# frozen_string_literal: true

require 'apartment/elevators/generic'

module Apartment
  module Elevators
    # Tenant from HTTP header. For infrastructure that injects tenant identity at the edge
    # (CloudFront, Nginx, API gateway).
    #
    # The trusted: flag is consumed by the Railtie for a boot-time warning;
    # the elevator itself behaves identically regardless of trust level.
    class Header < Generic
      attr_reader :raw_header

      def initialize(app, header: 'X-Tenant-Id', **_options)
        super(app)
        @header_name = "HTTP_#{header.upcase.tr('-', '_')}"
        @raw_header = header.freeze
      end

      def parse_tenant_name(request)
        request.get_header(@header_name)
      end
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/unit/elevators/header_spec.rb`
Expected: All pass

- [ ] **Step 5: Commit**

```bash
git add lib/apartment/elevators/header.rb spec/unit/elevators/header_spec.rb
git commit -m "Add v4 Header elevator: HTTP header-based tenant resolution"
```

---

## Task 8: Railtie changes

**Files:**
- Modify: `lib/apartment/railtie.rb`
- Modify: `spec/unit/railtie_spec.rb`

- [ ] **Step 1: Write failing tests for Railtie changes**

Add to `spec/unit/railtie_spec.rb` inside the `describe '.resolve_elevator_class'` block:

```ruby
it 'passes through a class without resolution' do
  klass = Apartment::Railtie.resolve_elevator_class(Apartment::Elevators::Subdomain)
  expect(klass).to(eq(Apartment::Elevators::Subdomain))
end

it 'passes through any custom class' do
  custom_class = Class.new(Apartment::Elevators::Generic)
  klass = Apartment::Railtie.resolve_elevator_class(custom_class)
  expect(klass).to(eq(custom_class))
end

it 'resolves :header to Apartment::Elevators::Header' do
  klass = Apartment::Railtie.resolve_elevator_class(:header)
  expect(klass).to(eq(Apartment::Elevators::Header))
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec appraisal rails-8.1-sqlite3 rspec spec/unit/railtie_spec.rb`
Expected: Failure (resolve_elevator_class doesn't handle class input)

- [ ] **Step 3: Update Railtie implementation**

Update `lib/apartment/railtie.rb`:

1. `resolve_elevator_class` — add class pass-through at top:
```ruby
def self.resolve_elevator_class(elevator)
  return elevator if elevator.is_a?(Class)

  class_name = "Apartment::Elevators::#{elevator.to_s.camelize}"
  require("apartment/elevators/#{elevator}")
  class_name.constantize
rescue NameError, LoadError => e
  available = Dir[File.join(__dir__, 'elevators', '*.rb')]
    .filter_map { |f| name = File.basename(f, '.rb'); name unless name == 'generic' }
  raise(Apartment::ConfigurationError,
        "Unknown elevator '#{elevator}': #{e.message}. " \
        "Available elevators: #{available.join(', ')}")
end
```

2. Middleware initializer — `**opts` + Header warning:
```ruby
initializer 'apartment.middleware' do |app|
  next unless Apartment.config&.elevator

  elevator_class = Apartment::Railtie.resolve_elevator_class(Apartment.config.elevator)
  opts = Apartment.config.elevator_options || {}

  if elevator_class <= Apartment::Elevators::Header && !opts[:trusted]
    warn <<~WARNING
      [Apartment] WARNING: Header elevator with trusted: false.
      Header-based tenant resolution trusts the client to provide the correct tenant.
      Only use this when the header is injected by trusted infrastructure (CDN, reverse proxy)
      that strips client-supplied values.
    WARNING
  end

  app.middleware.use(elevator_class, **opts)
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec appraisal rails-8.1-sqlite3 rspec spec/unit/railtie_spec.rb`
Expected: All pass

- [ ] **Step 5: Run full unit test suite**

Run: `bundle exec rspec spec/unit/`
Expected: All pass

- [ ] **Step 6: Commit**

```bash
git add lib/apartment/railtie.rb spec/unit/railtie_spec.rb
git commit -m "v4 Railtie: keyword args, class pass-through, Header trust warning"
```

---

## Task 9: Full suite green + CLAUDE.md updates

**Files:**
- Modify: `lib/apartment/elevators/CLAUDE.md` (update for v4 changes)
- Modify: `spec/CLAUDE.md` (add elevator test references)
- Modify: `lib/apartment/CLAUDE.md` (update elevator section)

- [ ] **Step 1: Run full unit tests**

Run: `bundle exec rspec spec/unit/`
Expected: All pass

- [ ] **Step 2: Run full unit tests across Rails versions**

Run: `bundle exec appraisal rspec spec/unit/`
Expected: All pass

- [ ] **Step 3: Run integration tests (if PostgreSQL available)**

Run: `DATABASE_ENGINE=postgresql bundle exec appraisal rails-8.1-postgresql rspec spec/integration/v4/request_lifecycle_spec.rb`
Expected: All pass (existing subdomain elevator integration test still works)

- [ ] **Step 4: Run rubocop**

Run: `bundle exec rubocop lib/apartment/elevators/ spec/unit/elevators/`
Expected: No offenses (fix any that appear)

- [ ] **Step 5: Update CLAUDE.md files**

Update `lib/apartment/elevators/CLAUDE.md` to reflect v4 changes (constructor-only config, Header elevator, no class-level setters).

Update `spec/CLAUDE.md` to reference `spec/unit/elevators/` test files.

Update `lib/apartment/CLAUDE.md` elevator section note.

- [ ] **Step 6: Commit**

```bash
git add lib/apartment/elevators/CLAUDE.md spec/CLAUDE.md lib/apartment/CLAUDE.md
git commit -m "Update CLAUDE.md files for v4 elevators"
```

---

## Task 10: Branch + PR

- [ ] **Step 1: Create feature branch (if not already on one)**

The work should be on a `man/v4-elevators` branch off `development`. If still on `development`, create the branch now and cherry-pick the commits.

- [ ] **Step 2: Push and create PR**

```bash
git push -u origin man/v4-elevators
gh pr create --base development --title "Phase 3: v4 Elevators" --body "..."
```

PR body should reference the design spec and list the changes.
