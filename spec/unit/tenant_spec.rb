# frozen_string_literal: true

require 'spec_helper'

RSpec.describe(Apartment::Tenant) do
  let(:mock_adapter) { double('Adapter') }

  before do
    Apartment.configure do |config|
      config.tenant_strategy = :schema
      config.tenants_provider = -> { %w[tenant1 tenant2] }
      config.default_tenant = 'public'
    end
    Apartment.adapter = mock_adapter
    Apartment::Current.reset
  end

  describe '.switch' do
    it 'requires a block' do
      expect { described_class.switch('tenant1') }.to(raise_error(ArgumentError, /requires a block/))
    end

    it 'sets Current.tenant and Current.previous_tenant within the block' do
      described_class.switch('tenant1') do
        expect(Apartment::Current.tenant).to(eq('tenant1'))
        expect(Apartment::Current.previous_tenant).to(be_nil)
      end
    end

    it 'tracks the previous tenant when nested' do
      Apartment::Current.tenant = 'base'

      described_class.switch('tenant1') do
        expect(Apartment::Current.tenant).to(eq('tenant1'))
        expect(Apartment::Current.previous_tenant).to(eq('base'))
      end
    end

    it 'restores the previous tenant after the block' do
      Apartment::Current.tenant = 'base'

      described_class.switch('tenant1') {}

      expect(Apartment::Current.tenant).to(eq('base'))
      expect(Apartment::Current.previous_tenant).to(be_nil)
    end

    it 'restores the previous tenant on exception' do
      Apartment::Current.tenant = 'base'

      expect do
        described_class.switch('tenant1') { raise('boom') }
      end.to(raise_error(RuntimeError, 'boom'))

      expect(Apartment::Current.tenant).to(eq('base'))
      expect(Apartment::Current.previous_tenant).to(be_nil)
    end

    it 'supports nesting' do
      described_class.switch('tenant1') do
        described_class.switch('tenant2') do
          expect(Apartment::Current.tenant).to(eq('tenant2'))
          expect(Apartment::Current.previous_tenant).to(eq('tenant1'))
        end
        expect(Apartment::Current.tenant).to(eq('tenant1'))
      end
    end
  end

  describe '.switch!' do
    it 'sets the current tenant without a block' do
      described_class.switch!('tenant1')
      expect(Apartment::Current.tenant).to(eq('tenant1'))
    end

    it 'sets previous_tenant to the prior tenant' do
      Apartment::Current.tenant = 'base'
      described_class.switch!('tenant1')
      expect(Apartment::Current.previous_tenant).to(eq('base'))
    end
  end

  describe '.current' do
    it 'returns Current.tenant when set' do
      Apartment::Current.tenant = 'tenant1'
      expect(described_class.current).to(eq('tenant1'))
    end

    it 'falls back to config.default_tenant when Current.tenant is nil' do
      expect(described_class.current).to(eq('public'))
    end

    it 'returns nil when no config and no current tenant' do
      Apartment.clear_config
      expect(described_class.current).to(be_nil)
    end
  end

  describe '.default_tenant' do
    it 'returns the configured default tenant' do
      expect(described_class.default_tenant).to(eq('public'))
    end

    it 'is independent of the current tenant context' do
      described_class.switch!('tenant1')
      expect(described_class.default_tenant).to(eq('public'))
    end

    it 'returns nil when no config is set' do
      Apartment.clear_config
      expect(described_class.default_tenant).to(be_nil)
    end
  end

  describe '.reset' do
    it 'sets tenant to default_tenant' do
      Apartment::Current.tenant = 'tenant1'
      described_class.reset
      expect(Apartment::Current.tenant).to(eq('public'))
    end

    it 'sets previous_tenant to the prior tenant' do
      Apartment::Current.tenant = 'tenant1'
      described_class.reset
      expect(Apartment::Current.previous_tenant).to(eq('tenant1'))
    end
  end

  describe '.tenant_switched?' do
    it 'returns false when Current.tenant is nil' do
      Apartment::Current.tenant = nil
      expect(described_class.tenant_switched?).to(be(false))
    end

    it 'returns true after switch!' do
      described_class.switch!('tenant1')
      expect(described_class.tenant_switched?).to(be(true))
    end

    it 'returns true after reset (reset is an explicit entry into default_tenant)' do
      described_class.switch!('tenant1')
      described_class.reset
      # reset switches to default_tenant ('public') via switch!, which sets
      # Current.tenant. tenant_switched? reports true — reset is an explicit entry
      # into the default tenant, distinct from "no tenant ever entered".
      expect(described_class.tenant_switched?).to(be(true))
    end

    it 'returns false outside a switch block, true inside' do
      Apartment::Current.tenant = nil
      expect(described_class.tenant_switched?).to(be(false))
      described_class.switch('tenant1') do
        expect(described_class.tenant_switched?).to(be(true))
      end
      expect(described_class.tenant_switched?).to(be(false))
    end

    it 'distinguishes from .current when nothing has been entered' do
      Apartment::Current.tenant = nil
      expect(described_class.current).to(eq('public'))
      expect(described_class.tenant_switched?).to(be(false))
    end

    it 'no longer responds to the pre-rename names (no aliases)' do
      expect(described_class).not_to(respond_to(:inside_tenant?))
      expect(described_class).not_to(respond_to(:assert_inside_tenant!))
    end
  end

  describe '.assert_tenant_switched!' do
    it 'raises when Current.tenant is nil' do
      Apartment::Current.tenant = nil
      expect { described_class.assert_tenant_switched! }
        .to(raise_error(Apartment::ApartmentError, /no explicit tenant context|Current.tenant is nil/))
    end

    it 'no-ops when a tenant has been entered' do
      described_class.switch!('tenant1')
      expect { described_class.assert_tenant_switched! }.not_to(raise_error)
    end

    it 'no-ops inside a switch block' do
      described_class.switch('tenant1') do
        expect { described_class.assert_tenant_switched! }.not_to(raise_error)
      end
    end

    it 'message points the caller at switch / switch!' do
      Apartment::Current.tenant = nil
      expect { described_class.assert_tenant_switched! }
        .to(raise_error(/Apartment::Tenant\.switch/))
    end

    it 'honors a custom message: kwarg' do
      Apartment::Current.tenant = nil
      expect { described_class.assert_tenant_switched!(message: 'cross_tenant: true required') }
        .to(raise_error(Apartment::ApartmentError, 'cross_tenant: true required'))
    end
  end

  describe '.switch default_tenant guard' do
    context 'when default_tenant_switch_allowed is true (default)' do
      it 'permits switch into the default tenant' do
        expect { described_class.switch('public') { :ok } }.not_to(raise_error)
      end
    end

    context 'when default_tenant_switch_allowed is false' do
      before do
        Apartment.configure do |c|
          c.tenant_strategy = :schema
          c.tenants_provider = -> { %w[tenant1 tenant2] }
          c.default_tenant = 'public'
          c.default_tenant_switch_allowed = false
        end
      end

      it 'raises on switch(default_tenant) block form' do
        expect { described_class.switch('public') { :ok } }
          .to(raise_error(Apartment::ApartmentError,
                          /switch\("public"\) is disabled.*default_tenant_switch_allowed/m))
      end

      it 'preserves the prior tenant context when the guard rejects the switch' do
        described_class.switch!('tenant1')
        expect { described_class.switch('public') { :ok } }.to(raise_error(Apartment::ApartmentError))
        # the guard raises before the switch mutates Current — context survives
        expect(described_class.current).to(eq('tenant1'))
      end

      it 'permits switch into a non-default tenant' do
        expect { described_class.switch('tenant1') { :ok } }.not_to(raise_error)
      end

      it 'permits switch!(default_tenant) (non-block bypass)' do
        expect { described_class.switch!('public') }.not_to(raise_error)
      end

      it 'permits Tenant.reset' do
        expect { described_class.reset }.not_to(raise_error)
      end

      it 'is inert when default_tenant is nil' do
        Apartment.configure do |c|
          c.tenant_strategy = :database_name
          c.tenants_provider = -> { %w[t1] }
          c.default_tenant_switch_allowed = false
        end
        # default_tenant is nil; no tenant name can match, so guard never fires.
        expect { described_class.switch('t1') { :ok } }.not_to(raise_error)
      end

      it 'raises on Symbol tenant matching String default_tenant' do
        # default_tenant = 'public' (String) from the surrounding configure
        expect { described_class.switch(:public) { :ok } }
          .to(raise_error(Apartment::ApartmentError, /switch\("public"\) is disabled/))
      end

      it 'raises on String tenant matching Symbol default_tenant' do
        Apartment.configure do |c|
          c.tenant_strategy = :schema
          c.tenants_provider = -> { %w[tenant1] }
          c.default_tenant = :public
          c.default_tenant_switch_allowed = false
        end
        expect { described_class.switch('public') { :ok } }
          .to(raise_error(Apartment::ApartmentError, /is disabled/))
      end

      it 'error message points at reset for block scope and switch! for non-block' do
        expect { described_class.switch('public') { :ok } }
          .to(raise_error(/Inside a block scope, call Apartment::Tenant\.reset.*non-block scopes.*Apartment::Tenant\.switch!/m))
      end
    end
  end

  describe '.init' do
    it 'delegates to adapter.process_pinned_models' do
      expect(mock_adapter).to(receive(:process_pinned_models))
      described_class.init
    end

    context 'resolve_excluded_models_shim' do
      it 'resolves excluded model strings and registers them as pinned' do
        model_class = Class.new
        stub_const('ShimTestModel', model_class)

        Apartment.configure do |config|
          config.tenant_strategy = :schema
          config.tenants_provider = -> { [] }
          config.default_tenant = 'public'
          config.excluded_models = ['ShimTestModel']
        end

        allow(mock_adapter).to(receive(:process_pinned_models))
        Apartment.adapter = mock_adapter

        described_class.init

        expect(Apartment.pinned_models).to(include(ShimTestModel))
      end

      it 'raises ConfigurationError for unresolvable model names' do
        Apartment.configure do |config|
          config.tenant_strategy = :schema
          config.tenants_provider = -> { [] }
          config.default_tenant = 'public'
          config.excluded_models = ['NonExistentModel']
        end

        allow(mock_adapter).to(receive(:process_pinned_models))
        Apartment.adapter = mock_adapter

        expect { described_class.init }.to(raise_error(
                                             Apartment::ConfigurationError,
                                             /Excluded model 'NonExistentModel' could not be resolved/
                                           ))
      end

      it 'skips models already in pinned_models registry (via pin_tenant)' do
        require 'apartment/concerns/model'
        model_class = Class.new(ActiveRecord::Base) do
          include Apartment::Model
        end
        stub_const('AlreadyPinnedModel', model_class)
        AlreadyPinnedModel.pin_tenant

        Apartment.configure do |config|
          config.tenant_strategy = :schema
          config.tenants_provider = -> { [] }
          config.default_tenant = 'public'
          config.excluded_models = ['AlreadyPinnedModel']
        end

        allow(mock_adapter).to(receive(:process_pinned_models))
        Apartment.adapter = mock_adapter

        # Already in registry via pin_tenant — should not double-register
        count_before = Apartment.pinned_models.size
        described_class.init
        expect(Apartment.pinned_models.size).to(eq(count_before))
      end
    end
  end

  describe '.each' do
    it 'requires a block' do
      expect { described_class.each }.to(raise_error(ArgumentError, /requires a block/))
    end

    it 'iterates over all tenants from tenants_provider' do
      visited = []
      described_class.each { |t| visited << t } # rubocop:disable Style/MapIntoArray
      expect(visited).to(eq(%w[tenant1 tenant2]))
    end

    it 'switches into each tenant for the duration of the block' do
      tenants_seen = []
      described_class.each { |_t| tenants_seen << Apartment::Current.tenant } # rubocop:disable Style/MapIntoArray
      expect(tenants_seen).to(eq(%w[tenant1 tenant2]))
    end

    it 'restores tenant context after iteration' do
      Apartment::Current.tenant = 'original'
      described_class.each { |_t| }
      expect(Apartment::Current.tenant).to(eq('original'))
    end

    it 'accepts a custom tenant list' do
      visited = []
      described_class.each(%w[custom1 custom2]) { |t| visited << t }
      expect(visited).to(eq(%w[custom1 custom2]))
    end

    it 'propagates exceptions from the block' do
      expect do
        described_class.each { raise('boom') } # rubocop:disable Lint/UnreachableLoop
      end.to(raise_error(RuntimeError, 'boom'))
    end

    it 'restores tenant context after an exception' do
      Apartment::Current.tenant = 'original'
      begin
        described_class.each { raise('boom') } # rubocop:disable Lint/UnreachableLoop
      rescue RuntimeError
        nil
      end
      expect(Apartment::Current.tenant).to(eq('original'))
    end

    it 'raises ConfigurationError when tenants_provider returns nil' do
      Apartment.configure do |config|
        config.tenant_strategy = :schema
        config.tenants_provider = ->(*) { nil } # rubocop:disable Style/NilLambda
        config.default_tenant = 'public'
      end
      Apartment.adapter = mock_adapter

      expect do
        described_class.each { |_t| }
      end.to(raise_error(Apartment::ConfigurationError, /tenants_provider must return an Enumerable/))
    end

    it 'raises ConfigurationError when Apartment is not configured' do
      Apartment.clear_config
      expect do
        described_class.each { |_t| }
      end.to(raise_error(Apartment::ConfigurationError, /not configured/))
    end

    it 'stops iteration on first exception (fail-fast)' do
      visited = []
      expect do
        described_class.each(%w[tenant1 tenant2 tenant3]) do |t|
          visited << t
          raise('fail on tenant2') if t == 'tenant2'
        end
      end.to(raise_error(RuntimeError, 'fail on tenant2'))
      expect(visited).to(eq(%w[tenant1 tenant2]))
    end

    it 'is a no-op for an empty tenant list' do
      called = false
      described_class.each([]) { |_t| called = true }
      expect(called).to(be(false))
    end

    it 'releases the connection after each tenant when release_connection: true' do
      allow(ActiveRecord::Base.connection_handler).to(receive(:clear_active_connections!))

      described_class.each(release_connection: true) { |_t| }

      expect(ActiveRecord::Base.connection_handler)
        .to(have_received(:clear_active_connections!).with(:all).twice)
    end

    it 'does not release connections by default' do
      allow(ActiveRecord::Base.connection_handler).to(receive(:clear_active_connections!))

      described_class.each { |_t| }

      expect(ActiveRecord::Base.connection_handler).not_to(have_received(:clear_active_connections!))
    end

    it 'releases the connection even when the block raises (release_connection: true)' do
      # Release is best-effort cleanup, not iteration semantics: a raising tenant
      # must still have its leased connection returned. Fail-fast is preserved —
      # the exception propagates and halts iteration (tenant2 is never visited).
      allow(ActiveRecord::Base.connection_handler).to(receive(:clear_active_connections!))

      expect do
        described_class.each(%w[tenant1 tenant2], release_connection: true) do |t|
          raise('boom') if t == 'tenant1'
        end
      end.to(raise_error(RuntimeError, 'boom'))

      expect(ActiveRecord::Base.connection_handler)
        .to(have_received(:clear_active_connections!).with(:all).once)
    end

    it 'returns the result of iterating the tenant list' do
      result = described_class.each(%w[a b]) { |_t| }
      expect(result).to(eq(%w[a b]))
    end
  end

  describe '.with_tenants_provider' do
    it 'requires a block' do
      expect { described_class.with_tenants_provider(['a']) }.to(raise_error(ArgumentError, /requires a block/))
    end

    it 'overrides the resolver for Apartment.tenant_names' do
      described_class.with_tenants_provider(%w[acme widgets]) do
        expect(Apartment.tenant_names).to(eq(%w[acme widgets]))
      end
    end

    it 'overrides the resolver for Tenant.each' do
      visited = []
      described_class.with_tenants_provider(%w[acme widgets]) do
        described_class.each { |t| visited << t }
      end
      expect(visited).to(eq(%w[acme widgets]))
    end

    it 'restores the ambient resolver after the block' do
      described_class.with_tenants_provider(%w[acme]) {}
      expect(Apartment.tenant_names).to(eq(%w[tenant1 tenant2]))
    end

    it 'restores the ambient resolver after an exception in the block' do
      begin
        described_class.with_tenants_provider(%w[acme]) { raise('boom') }
      rescue RuntimeError
        nil
      end
      expect(Apartment.tenant_names).to(eq(%w[tenant1 tenant2]))
    end

    it 'coerces a String to a single-element Array of strings' do
      described_class.with_tenants_provider('acme') do
        expect(Apartment.tenant_names).to(eq(%w[acme]))
      end
    end

    it 'coerces a Symbol to a single-element Array of strings' do
      described_class.with_tenants_provider(:acme) do
        expect(Apartment.tenant_names).to(eq(%w[acme]))
      end
    end

    it 'coerces an Array of mixed Strings and Symbols to strings' do
      described_class.with_tenants_provider([:acme, 'widgets']) do
        expect(Apartment.tenant_names).to(eq(%w[acme widgets]))
      end
    end

    it 'freezes the coerced override Array' do
      described_class.with_tenants_provider(%w[acme widgets]) do
        expect(Apartment::Current.tenant_override).to(be_frozen)
      end
    end

    it 'honors an empty Array (Tenant.each yields zero times)' do
      visited = []
      described_class.with_tenants_provider([]) do
        described_class.each { |t| visited << t }
      end
      expect(visited).to(eq([]))
    end

    it 'accepts a callable and re-evaluates it on every tenant_names access' do
      calls = 0
      callable = lambda do
        calls += 1
        ["tenant_#{calls}"]
      end

      described_class.with_tenants_provider(callable) do
        expect(Apartment.tenant_names).to(eq(%w[tenant_1]))
        expect(Apartment.tenant_names).to(eq(%w[tenant_2]))
      end
      expect(calls).to(eq(2))
    end

    it 'raises ConfigurationError when a callable override returns a non-Enumerable' do
      callable = -> { 42 }
      described_class.with_tenants_provider(callable) do
        expect do
          Apartment.tenant_names
        end.to(raise_error(Apartment::ConfigurationError, /tenant_override must return an Enumerable/))
      end
    end

    it 'fully replaces an outer override when nested' do
      seen_inside = nil
      described_class.with_tenants_provider(%w[outer1 outer2]) do
        described_class.with_tenants_provider(%w[inner]) do
          seen_inside = Apartment.tenant_names
        end
        expect(Apartment.tenant_names).to(eq(%w[outer1 outer2]))
      end
      expect(seen_inside).to(eq(%w[inner]))
    end

    it 'does not clear an outer override when the inner call raises ArgumentError' do
      described_class.with_tenants_provider(%w[outer]) do
        expect do
          described_class.with_tenants_provider(%w[inner]) # no block
        end.to(raise_error(ArgumentError, /requires a block/))
        expect(Apartment::Current.tenant_override).to(eq(%w[outer]))
      end
    end

    it 'does not clear an outer override when coercion raises ArgumentError' do
      described_class.with_tenants_provider(%w[outer]) do
        expect do
          described_class.with_tenants_provider(nil) { :unreachable }
        end.to(raise_error(ArgumentError, /callable, String, Symbol/))
        expect(Apartment::Current.tenant_override).to(eq(%w[outer]))
      end
    end

    it 'raises ArgumentError for nil' do
      expect do
        described_class.with_tenants_provider(nil) { :unreachable }
      end.to(raise_error(ArgumentError, /callable, String, Symbol/))
    end

    it 'raises ArgumentError for a Hash' do
      expect do
        described_class.with_tenants_provider({ acme: 1 }) { :unreachable }
      end.to(raise_error(ArgumentError, /callable, String, Symbol/))
    end

    it 'raises ArgumentError for an arbitrary object' do
      expect do
        described_class.with_tenants_provider(Object.new) { :unreachable }
      end.to(raise_error(ArgumentError, /callable, String, Symbol/))
    end

    it 'raises ArgumentError for an Array containing a non-String/Symbol entry' do
      expect do
        described_class.with_tenants_provider(['acme', 42]) { :unreachable }
      end.to(raise_error(ArgumentError, /Array entries must be String or Symbol/))
    end
  end

  describe '.with_tenants' do
    it 'delegates to with_tenants_provider with the splat as the source' do
      visited = []
      described_class.with_tenants('acme', 'widgets') do
        described_class.each { |t| visited << t }
      end
      expect(visited).to(eq(%w[acme widgets]))
    end

    it 'with no arguments yields zero iterations through Tenant.each' do
      visited = []
      described_class.with_tenants do
        described_class.each { |t| visited << t }
      end
      expect(visited).to(eq([]))
    end

    it 'requires a block' do
      expect { described_class.with_tenants('acme') }.to(raise_error(ArgumentError, /requires a block/))
    end
  end

  describe '.create' do
    it 'delegates to adapter' do
      expect(mock_adapter).to(receive(:create).with('new_tenant'))
      described_class.create('new_tenant')
    end
  end

  describe '.drop' do
    it 'delegates to adapter' do
      expect(mock_adapter).to(receive(:drop).with('old_tenant'))
      described_class.drop('old_tenant')
    end
  end

  describe '.migrate' do
    it 'delegates to adapter with tenant' do
      expect(mock_adapter).to(receive(:migrate).with('tenant1', nil))
      described_class.migrate('tenant1')
    end

    it 'delegates to adapter with tenant and version' do
      expect(mock_adapter).to(receive(:migrate).with('tenant1', 20_260_101_000_000))
      described_class.migrate('tenant1', 20_260_101_000_000)
    end
  end

  describe '.seed' do
    it 'delegates to adapter' do
      expect(mock_adapter).to(receive(:seed).with('tenant1'))
      described_class.seed('tenant1')
    end
  end

  describe 'adapter guard' do
    it 'raises ConfigurationError when adapter is not configured' do
      Apartment.clear_config
      expect { described_class.create('tenant1') }.to(raise_error(
                                                        Apartment::ConfigurationError, /not configured/
                                                      ))
    end
  end

  describe '.pool_stats' do
    it 'delegates to pool_manager.stats' do
      stats = { total: 2, active: 1 }
      allow(Apartment.pool_manager).to(receive(:stats).and_return(stats))
      expect(described_class.pool_stats).to(eq(stats))
    end

    it 'returns empty hash when pool_manager is nil' do
      Apartment.clear_config
      expect(described_class.pool_stats).to(eq({}))
    end
  end

  describe '.in_tenant? / .in_default_tenant? (identity axis)' do
    it 'A. forgot to switch (inertia -> default): not in tenant, in default' do
      Apartment::Current.tenant = nil
      expect(described_class.in_tenant?).to(be(false))
      expect(described_class.in_default_tenant?).to(be(true))
    end

    it 'B. explicit switch!(default): not in tenant, in default' do
      described_class.switch!('public')
      expect(described_class.in_tenant?).to(be(false))
      expect(described_class.in_default_tenant?).to(be(true))
    end

    it 'C. real tenant: in tenant, not in default' do
      described_class.switch!('tenant1')
      expect(described_class.in_tenant?).to(be(true))
      expect(described_class.in_default_tenant?).to(be(false))
    end

    it 'normalizes symbols against the configured default' do
      described_class.switch!(:public)
      expect(described_class.in_tenant?).to(be(false))
      expect(described_class.in_default_tenant?).to(be(true))
    end

    it 'in_default_tenant? is false when no default_tenant is configured' do
      Apartment.configure do |c|
        c.tenant_strategy = :database_name
        c.tenants_provider = -> { %w[tenant1] }
        c.default_tenant = nil
      end
      Apartment.adapter = mock_adapter
      Apartment::Current.tenant = nil
      expect(described_class.in_default_tenant?).to(be(false))
    end
  end

  describe '.require_tenant! / .require_default_tenant! (raising guards)' do
    it 'require_tenant! returns the normalized name inside a real tenant' do
      described_class.switch!('tenant1')
      expect(described_class.require_tenant!).to(eq('tenant1'))
    end

    it 'require_tenant! raises TenantRequired on default-by-inertia' do
      Apartment::Current.tenant = nil
      expect { described_class.require_tenant! }
        .to(raise_error(Apartment::TenantRequired, /non-default tenant/))
    end

    it 'require_tenant! raises TenantRequired on explicit switch!(default)' do
      described_class.switch!('public')
      expect { described_class.require_tenant! }
        .to(raise_error(Apartment::TenantRequired))
    end

    it 'require_default_tenant! returns the default name when in default' do
      described_class.switch!('public')
      expect(described_class.require_default_tenant!).to(eq('public'))
    end

    it 'require_default_tenant! passes on default-by-inertia' do
      Apartment::Current.tenant = nil
      expect(described_class.require_default_tenant!).to(eq('public'))
    end

    it 'require_default_tenant! raises DefaultTenantRequired in a real tenant' do
      described_class.switch!('tenant1')
      expect { described_class.require_default_tenant! }
        .to(raise_error(Apartment::DefaultTenantRequired, /"public"/))
    end

    it 'require_default_tenant! raises DefaultTenantNotConfigured when no default set' do
      Apartment.configure do |c|
        c.tenant_strategy = :database_name
        c.tenants_provider = -> { %w[tenant1] }
        c.default_tenant = nil
      end
      Apartment.adapter = mock_adapter
      Apartment::Current.tenant = nil
      expect { described_class.require_default_tenant! }
        .to(raise_error(Apartment::DefaultTenantNotConfigured))
    end
  end

  describe '.cache_namespace' do
    it 'returns the normalized tenant name inside a real tenant' do
      described_class.switch!('tenant1')
      expect(described_class.cache_namespace).to(eq('tenant1'))
    end

    it 'raises TenantRequired outside a real tenant (fail-closed for the proc)' do
      Apartment::Current.tenant = nil
      expect { described_class.cache_namespace }
        .to(raise_error(Apartment::TenantRequired))
    end

    it 'works as a namespace proc' do
      proc = -> { described_class.cache_namespace }
      described_class.switch('tenant1') { expect(proc.call).to(eq('tenant1')) }
    end

    it 'fails closed on an empty-string tenant (switch! bypasses name validation)' do
      described_class.switch!('')
      expect(described_class.in_tenant?).to(be(false))
      expect { described_class.cache_namespace }
        .to(raise_error(Apartment::TenantRequired))
    end

    it 'succeeds for a real tenant even when no default_tenant is configured' do
      Apartment.configure do |c|
        c.tenant_strategy = :database_name
        c.tenants_provider = -> { %w[tenant1] }
        c.default_tenant = nil
      end
      Apartment.adapter = mock_adapter
      described_class.switch!('tenant1')
      expect(described_class.require_tenant!).to(eq('tenant1'))
      expect(described_class.cache_namespace).to(eq('tenant1'))
    end
  end

  describe '.with_default_tenant' do
    it 'requires a block' do
      expect { described_class.with_default_tenant }
        .to(raise_error(ArgumentError, /requires a block/))
    end

    it 'does not clobber the current context when called without a block' do
      described_class.switch!('tenant1')
      expect { described_class.with_default_tenant }.to(raise_error(ArgumentError))
      expect(described_class.current).to(eq('tenant1'))
    end

    it 'runs the block in the default tenant' do
      described_class.switch!('tenant1')
      described_class.with_default_tenant do
        expect(described_class.current).to(eq('public'))
        expect(described_class.in_default_tenant?).to(be(true))
      end
    end

    it 'restores the prior tenant on normal exit' do
      described_class.switch!('tenant1')
      described_class.with_default_tenant { :noop }
      expect(described_class.current).to(eq('tenant1'))
    end

    it 'restores prior context (including nil) on raise' do
      Apartment::Current.tenant = nil
      expect do
        described_class.with_default_tenant { raise('boom') }
      end.to(raise_error('boom'))
      expect(Apartment::Current.tenant).to(be_nil)
    end

    it 'bypasses the strict-mode default_tenant switch guard' do
      Apartment.configure do |c|
        c.tenant_strategy = :schema
        c.tenants_provider = -> { %w[tenant1] }
        c.default_tenant = 'public'
        c.default_tenant_switch_allowed = false
      end
      Apartment.adapter = mock_adapter
      Apartment::Current.tenant = nil
      expect { described_class.with_default_tenant { :ok } }.not_to(raise_error)
    end

    it 'raises DefaultTenantNotConfigured when no default_tenant is configured' do
      Apartment.configure do |c|
        c.tenant_strategy = :database_name
        c.tenants_provider = -> { %w[tenant1] }
        c.default_tenant = nil
      end
      Apartment.adapter = mock_adapter
      described_class.switch!('tenant1')
      expect { described_class.with_default_tenant { :unreached } }
        .to(raise_error(Apartment::DefaultTenantNotConfigured))
      # raises before touching context — prior tenant is preserved
      expect(described_class.current).to(eq('tenant1'))
    end

    it 'nests: restores each enclosing tenant context as blocks unwind' do
      described_class.switch('tenant1') do
        described_class.with_default_tenant do
          expect(described_class.in_default_tenant?).to(be(true))
          described_class.with_default_tenant { :inner }
          # inner unwinds back to the (still default) enclosing context
          expect(described_class.current).to(eq('public'))
        end
        # outer with_default_tenant unwinds back to tenant1
        expect(described_class.current).to(eq('tenant1'))
      end
      # the switch block unwinds back to no explicit tenant
      expect(Apartment::Current.tenant).to(be_nil)
    end

    it 'short-circuits when already explicitly in the default, leaving previous_tenant untouched' do
      described_class.switch!('public')
      Apartment::Current.previous_tenant = 'sentinel'

      # The assign/restore branch is skipped: Current.tenant= is never called
      # during the no-op self-entry, so the sentinel previous_tenant survives.
      allow(Apartment::Current).to(receive(:tenant=).and_call_original)

      result = described_class.with_default_tenant do
        expect(described_class.current).to(eq('public'))
        :block_value
      end

      expect(result).to(eq(:block_value))
      expect(Apartment::Current).not_to(have_received(:tenant=))
      expect(Apartment::Current.previous_tenant).to(eq('sentinel'))
    end

    it 'short-circuits across a symbol/string mismatch (normalizes like the sibling guards)' do
      # default_tenant is the string 'public'; entering with a symbol-valued
      # Current.tenant is still the same tenant. The predicate must normalize
      # with to_s (as in_default_tenant?/require_default_tenant! do), not raw ==.
      described_class.switch!(:public)
      allow(Apartment::Current).to(receive(:tenant=).and_call_original)

      described_class.with_default_tenant { :noop }

      expect(Apartment::Current).not_to(have_received(:tenant=))
    end

    it 'leaves context intact when the block uses the block-form switch (the contract the short-circuit relies on)' do
      # The short-circuit path has no ensure. Block-form switch self-restores, so
      # a best-practice block leaves Current.tenant on the default afterward. (A
      # bare switch!/Current.tenant= would leak, but those are anti-patterns.)
      described_class.switch!('public')

      described_class.with_default_tenant do
        described_class.switch('tenant1') { :inner_work }
        expect(described_class.current).to(eq('public'))
      end

      expect(described_class.current).to(eq('public'))
    end

    it 'still enters from ambient nil (raw predicate, not effective identity)' do
      Apartment::Current.tenant = nil

      described_class.with_default_tenant do
        # Proves we did NOT broaden to in_default_tenant?: from ambient nil the
        # full assign path runs, so the explicitness axis sees an entered tenant.
        expect(described_class.current).to(eq('public'))
        expect(described_class.tenant_switched?).to(be(true))
      end

      expect(Apartment::Current.tenant).to(be_nil)
    end

    it 'still enters from a real tenant and restores it on exit' do
      described_class.switch!('tenant1')

      described_class.with_default_tenant do
        expect(described_class.current).to(eq('public'))
      end

      expect(described_class.current).to(eq('tenant1'))
    end
  end
end
