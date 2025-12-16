# frozen_string_literal: true

require 'spec_helper'
require 'apartment/tasks/task_helper'

describe Apartment::TaskHelper do
  before do
    Apartment.reset
    allow(Apartment).to(receive_messages(tenant_names: %w[tenant1 tenant2 tenant3], default_tenant: 'public'))
  end

  describe '.tenants' do
    context 'without DB env var' do
      before { ENV.delete('DB') }

      it 'returns all tenant names from configuration' do
        expect(described_class.tenants).to(eq(%w[tenant1 tenant2 tenant3]))
      end
    end

    context 'with DB env var' do
      before { ENV['DB'] = 'custom1, custom2' }
      after { ENV.delete('DB') }

      it 'returns tenants from DB env var' do
        expect(described_class.tenants).to(eq(%w[custom1 custom2]))
      end
    end
  end

  describe '.tenants_without_default' do
    it 'excludes the default tenant' do
      allow(Apartment).to(receive(:tenant_names).and_return(%w[public tenant1 tenant2]))
      expect(described_class.tenants_without_default).to(eq(%w[tenant1 tenant2]))
    end

    it 'filters out empty strings' do
      allow(Apartment).to(receive(:tenant_names).and_return(['', 'tenant1', 'tenant2']))
      expect(described_class.tenants_without_default).to(eq(%w[tenant1 tenant2]))
    end

    it 'filters out nil values' do
      allow(Apartment).to(receive(:tenant_names).and_return([nil, 'tenant1', 'tenant2']))
      expect(described_class.tenants_without_default).to(eq(%w[tenant1 tenant2]))
    end

    it 'filters out whitespace-only strings' do
      allow(Apartment).to(receive(:tenant_names).and_return(['  ', 'tenant1', 'tenant2']))
      expect(described_class.tenants_without_default).to(eq(%w[tenant1 tenant2]))
    end
  end

  describe '.fork_safe_platform?' do
    it 'returns true on Linux' do
      stub_const('RUBY_PLATFORM', 'x86_64-linux')
      expect(described_class.fork_safe_platform?).to(be(true))
    end

    it 'returns false on macOS' do
      stub_const('RUBY_PLATFORM', 'x86_64-darwin21')
      expect(described_class.fork_safe_platform?).to(be(false))
    end

    it 'returns false on Windows' do
      stub_const('RUBY_PLATFORM', 'x64-mingw32')
      expect(described_class.fork_safe_platform?).to(be(false))
    end
  end

  describe '.resolve_parallel_strategy' do
    context 'with explicit :threads strategy' do
      before { allow(Apartment).to(receive(:parallel_strategy).and_return(:threads)) }

      it 'returns :threads' do
        expect(described_class.resolve_parallel_strategy).to(eq(:threads))
      end
    end

    context 'with explicit :processes strategy' do
      before { allow(Apartment).to(receive(:parallel_strategy).and_return(:processes)) }

      it 'returns :processes' do
        expect(described_class.resolve_parallel_strategy).to(eq(:processes))
      end
    end

    context 'with :auto strategy' do
      before { allow(Apartment).to(receive(:parallel_strategy).and_return(:auto)) }

      it 'returns :processes on Linux' do
        stub_const('RUBY_PLATFORM', 'x86_64-linux')
        expect(described_class.resolve_parallel_strategy).to(eq(:processes))
      end

      it 'returns :threads on macOS' do
        stub_const('RUBY_PLATFORM', 'x86_64-darwin21')
        expect(described_class.resolve_parallel_strategy).to(eq(:threads))
      end
    end
  end

  describe '.with_advisory_locks_disabled' do
    before do
      ENV.delete('DISABLE_ADVISORY_LOCKS')
    end

    after do
      ENV.delete('DISABLE_ADVISORY_LOCKS')
    end

    context 'when parallel_migration_threads is 0' do
      before { allow(Apartment).to(receive(:parallel_migration_threads).and_return(0)) }

      it 'does not set DISABLE_ADVISORY_LOCKS' do
        described_class.with_advisory_locks_disabled do
          expect(ENV.fetch('DISABLE_ADVISORY_LOCKS', nil)).to(be_nil)
        end
      end
    end

    context 'when parallel_migration_threads > 0 and manage_advisory_locks is true' do
      before do
        allow(Apartment).to(receive_messages(parallel_migration_threads: 4, manage_advisory_locks: true))
      end

      it 'sets DISABLE_ADVISORY_LOCKS during block execution' do
        described_class.with_advisory_locks_disabled do
          expect(ENV.fetch('DISABLE_ADVISORY_LOCKS', nil)).to(eq('true'))
        end
      end

      it 'restores ENV after block completes' do
        described_class.with_advisory_locks_disabled { nil }
        expect(ENV.fetch('DISABLE_ADVISORY_LOCKS', nil)).to(be_nil)
      end

      it 'restores original ENV value if it existed' do
        ENV['DISABLE_ADVISORY_LOCKS'] = 'original'
        described_class.with_advisory_locks_disabled { nil }
        expect(ENV.fetch('DISABLE_ADVISORY_LOCKS', nil)).to(eq('original'))
      end
    end

    context 'when manage_advisory_locks is false' do
      before do
        allow(Apartment).to(receive_messages(parallel_migration_threads: 4, manage_advisory_locks: false))
      end

      it 'does not set DISABLE_ADVISORY_LOCKS' do
        described_class.with_advisory_locks_disabled do
          expect(ENV.fetch('DISABLE_ADVISORY_LOCKS', nil)).to(be_nil)
        end
      end
    end
  end

  describe '.each_tenant_sequential' do
    before do
      allow(Apartment).to(receive(:tenant_names).and_return(%w[public tenant1 tenant2]))
      allow(Rails.application).to(receive(:executor).and_return(double(wrap: nil)))
      allow(Rails.application.executor).to(receive(:wrap).and_yield)
    end

    it 'returns Result structs for each tenant' do
      results = described_class.each_tenant_sequential { |_tenant| nil }
      expect(results.size).to(eq(2))
      expect(results).to(all(be_a(Apartment::TaskHelper::Result)))
    end

    it 'marks successful operations' do
      results = described_class.each_tenant_sequential { |_tenant| nil }
      expect(results).to(all(have_attributes(success: true, error: nil)))
    end

    it 'captures errors without stopping iteration' do
      results = described_class.each_tenant_sequential do |tenant|
        raise('Test error') if tenant == 'tenant1'
      end

      expect(results.find { |r| r.tenant == 'tenant1' }).to(have_attributes(success: false))
      expect(results.find { |r| r.tenant == 'tenant2' }).to(have_attributes(success: true))
    end
  end

  describe '.display_summary' do
    let(:successful_results) do
      [
        Apartment::TaskHelper::Result.new(tenant: 'tenant1', success: true, error: nil),
        Apartment::TaskHelper::Result.new(tenant: 'tenant2', success: true, error: nil),
      ]
    end

    let(:mixed_results) do
      [
        Apartment::TaskHelper::Result.new(tenant: 'tenant1', success: true, error: nil),
        Apartment::TaskHelper::Result.new(tenant: 'tenant2', success: false, error: 'Connection failed'),
      ]
    end

    it 'does nothing with empty results' do
      expect { described_class.display_summary('Test', []) }.not_to(output.to_stdout)
    end

    it 'outputs success count' do
      expect { described_class.display_summary('Migration', successful_results) }
        .to(output(%r{Succeeded: 2/2 tenants}).to_stdout)
    end

    it 'outputs failure details when present' do
      expect { described_class.display_summary('Migration', mixed_results) }
        .to(output(/Failed: 1 tenants.*tenant2: Connection failed/m).to_stdout)
    end
  end

  describe Apartment::TaskHelper::Result do
    it 'is a Struct with tenant, success, and error fields' do
      result = described_class.new(tenant: 'test', success: true, error: nil)
      expect(result.tenant).to(eq('test'))
      expect(result.success).to(be(true))
      expect(result.error).to(be_nil)
    end
  end
end
