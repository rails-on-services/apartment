# frozen_string_literal: true

require 'spec_helper'
require 'apartment/tenant_validator'

RSpec.describe(Apartment::TenantValidator) do
  # Track validators built per example so notification subscriptions (added in
  # Task 3) are torn down. The respond_to? guard keeps this forward-compatible:
  # #shutdown does not exist until Task 3.
  def build_validator(**opts)
    validator = described_class.new(**opts)
    (@built_validators ||= []) << validator
    validator
  end

  after do
    (@built_validators || []).each { |v| v.shutdown if v.respond_to?(:shutdown) }
  end

  def configure(provider)
    Apartment.configure do |c|
      c.tenant_strategy = :schema
      c.default_tenant = 'public'
      c.tenants_provider = provider
    end
  end

  describe '#call' do
    it 'returns true for a name the provider lists' do
      configure(-> { %w[acme widgets] })
      expect(build_validator.call('acme')).to(be(true))
    end

    it 'returns false for a name the provider does not list' do
      configure(-> { %w[acme widgets] })
      expect(build_validator.call('ghost')).to(be(false))
    end

    it 'does not call the provider on every request (memoizes)' do
      calls = 0
      configure(lambda {
        calls += 1
        %w[acme]
      })
      validator = build_validator
      5.times { validator.call('acme') }
      expect(calls).to(eq(1))
    end

    it 'heals on a miss: a name added to the source becomes valid after a rebuild' do
      names = %w[acme]
      configure(-> { names })
      validator = build_validator(rebuild_interval: 0)
      expect(validator.call('widgets')).to(be(false))
      names << 'widgets'
      expect(validator.call('widgets')).to(be(true))
    end

    it 'rate-limits rebuilds: repeated misses inside the interval hit the source once' do
      calls = 0
      configure(lambda {
        calls += 1
        %w[acme]
      })
      validator = build_validator(rebuild_interval: 3600)
      10.times { validator.call('ghost') }
      expect(calls).to(eq(1)) # one lazy build; further misses are rate-limited
    end

    it 'rebuilds after the positive-set TTL' do
      names = %w[acme]
      configure(-> { names })
      validator = build_validator(positive_ttl: 0)
      expect(validator.call('acme')).to(be(true))
      names.replace(%w[widgets])
      expect(validator.call('acme')).to(be(false))
    end
  end

  describe 'lifecycle invalidation' do
    it 'adds a tenant on a create.apartment notification' do
      configure(-> { %w[acme] })
      validator = build_validator
      expect(validator.call('newco')).to(be(false))
      ActiveSupport::Notifications.instrument('create.apartment', tenant: 'newco') {}
      expect(validator.call('newco')).to(be(true))
    end

    it 'removes a tenant on a drop.apartment notification' do
      configure(-> { %w[acme widgets] })
      validator = build_validator
      expect(validator.call('widgets')).to(be(true))
      ActiveSupport::Notifications.instrument('drop.apartment', tenant: 'widgets') {}
      expect(validator.call('widgets')).to(be(false))
    end

    it 'stops responding to notifications after #shutdown' do
      configure(-> { %w[acme] })
      validator = build_validator
      validator.shutdown
      ActiveSupport::Notifications.instrument('create.apartment', tenant: 'newco') {}
      expect(validator.call('newco')).to(be(false))
    end

    it 'evicts a tenant added via Apartment::Lifecycle.notify_created' do
      configure(-> { %w[acme] })
      validator = build_validator
      expect(validator.call('newco')).to(be(false))
      Apartment::Lifecycle.notify_created('newco')
      expect(validator.call('newco')).to(be(true))
    end

    it 'evicts a tenant removed via Apartment::Lifecycle.notify_dropped' do
      configure(-> { %w[acme widgets] })
      validator = build_validator
      expect(validator.call('widgets')).to(be(true))
      Apartment::Lifecycle.notify_dropped('widgets')
      expect(validator.call('widgets')).to(be(false))
    end
  end

  describe 'fail-open on source error' do
    it 'allows any name when tenants_provider raises' do
      configure(-> { raise(StandardError, 'provider down') })
      expect(build_validator.call('anything')).to(be(true))
    end

    it 'does not let a logging failure escape into the request path' do
      configure(-> { raise(StandardError, 'provider down') })
      broken_logger = double('logger')
      allow(broken_logger).to(receive(:error).and_raise(IOError, 'log stream closed'))
      stub_const('Rails', double(logger: broken_logger))

      expect(build_validator.call('anything')).to(be(true))
    end

    it 'fails open when tenants_provider returns nil' do
      configure(-> {}) # an empty lambda returns nil
      expect(build_validator.call('anything')).to(be(true))
    end

    it 'fails open when tenants_provider returns a non-Enumerable' do
      configure(-> { 'acme' }) # a stray scalar, not a list of names
      expect(build_validator.call('widgets')).to(be(true))
    end

    it 'treats an empty list as zero tenants (404s unknown names), not a source error' do
      configure(-> { [] })
      expect(build_validator.call('anything')).to(be(false))
    end
  end

  describe 'concurrency' do
    it 'does not false-404 a valid tenant while the first build is in progress' do
      provider_running = Queue.new
      finish_provider = Queue.new
      configure(lambda {
        provider_running << true
        finish_provider.pop
        %w[acme]
      })
      validator = build_validator
      results = Concurrent::Hash.new

      t1 = Thread.new { results[:t1] = validator.call('acme') }
      provider_running.pop          # t1 is blocked inside the first build's provider call
      t2 = Thread.new { results[:t2] = validator.call('acme') }
      sleep(0.05)                   # give t2 time to reach the (blocking) rebuild
      finish_provider << true       # release the provider
      [t1, t2].each(&:join)

      expect(results).to(eq(t1: true, t2: true))
    end

    it 'preserves a create.apartment notification that lands mid-rebuild' do
      provider_running = Queue.new
      finish_provider = Queue.new
      configure(lambda {
        provider_running << true
        finish_provider.pop
        %w[acme]                    # the provider snapshot excludes newco
      })
      validator = build_validator
      builder = Thread.new { validator.call('acme') }
      provider_running.pop          # the rebuild is inside provider.call
      ActiveSupport::Notifications.instrument('create.apartment', tenant: 'newco') {}
      finish_provider << true
      builder.join

      expect(validator.call('newco')).to(be(true))
    end
  end
end
