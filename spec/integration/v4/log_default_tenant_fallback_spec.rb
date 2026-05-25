# frozen_string_literal: true

require 'spec_helper'
require 'logger'
require 'stringio'
require_relative 'support'

# End-to-end proof of the failure mode the log_default_tenant_fallback
# diagnostic surfaces: a relation captured inside Tenant.switch and
# accessed afterwards silently re-resolves connection_pool on the
# consumer fiber. With Apartment::Current.tenant.nil?, ConnectionHandling
# falls through to super and the query runs against the DEFAULT tenant
# -- wrong data, no error.
#
# Without the diagnostic: the test demonstrates the silent failure mode
# unchanged (gem behavior is preserved; this is a passive diagnostic).
# With the diagnostic: the same fallback emits a debug log line tagged
# "[Apartment] tenant=nil" with the caller site, dedup'd per call site.
#
# This is the consumer-fiber re-resolution case documented in
# docs/designs/apartment-v4.md "Async query correctness".
RSpec.describe('log_default_tenant_fallback integration', :integration,
               skip: (V4_INTEGRATION_AVAILABLE ? false : 'requires ActiveRecord + database gem')) do
  include V4IntegrationHelper

  let(:tmp_dir) { Dir.mktmpdir('apartment_diag') }
  let(:tenants) { %w[acme] }
  let(:log_io) { StringIO.new }
  let(:logger) { Logger.new(log_io).tap { |l| l.level = Logger::DEBUG } }

  before do
    V4IntegrationHelper.ensure_test_database! unless V4IntegrationHelper.sqlite?
    @connection_config = V4IntegrationHelper.establish_default_connection!(tmp_dir: tmp_dir)
    stub_const('Widget', Class.new(ActiveRecord::Base) { self.table_name = 'widgets' })
    # spec/support/rails_stub.rb provides a bare Rails stub; replace its
    # logger so the diagnostic has somewhere to write.
    allow(Rails).to(receive(:logger).and_return(logger))
    Apartment::Diagnostics.reset!
  end

  after do
    V4IntegrationHelper.cleanup_tenants!(tenants, Apartment.adapter) if Apartment.adapter
    Apartment.clear_config
    Apartment::Current.reset
    Apartment::Diagnostics.reset!
    ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:') if V4IntegrationHelper.sqlite?
    FileUtils.rm_rf(tmp_dir)
  end

  def populate_data(diagnostic:)
    Apartment.configure do |c|
      c.tenant_strategy = V4IntegrationHelper.tenant_strategy
      c.tenants_provider = -> { tenants }
      c.default_tenant = V4IntegrationHelper.default_tenant
      c.check_pending_migrations = false
      c.log_default_tenant_fallback = diagnostic
    end
    Apartment.adapter = V4IntegrationHelper.build_adapter(@connection_config)
    Apartment.activate!

    # Wrap default-tenant setup in switch(default_tenant) so the diagnostic
    # doesn't fire on legitimate setup paths and pollute log_io / dedup
    # before the actual test assertions run.
    Apartment::Tenant.switch(V4IntegrationHelper.default_tenant) do
      tenants.each { |t| Apartment.adapter.create(t) }
      V4IntegrationHelper.create_test_table!
      Widget.create!(name: 'in_default')
    end

    tenants.each do |t|
      Apartment::Tenant.switch(t) do
        V4IntegrationHelper.create_test_table!('widgets', connection: ActiveRecord::Base.connection)
        Widget.create!(name: "in_#{t}")
      end
    end

    # Reset the logger and dedup so the test starts with a clean slate
    # regardless of what setup happened to log.
    log_io.truncate(0)
    Apartment::Diagnostics.reset!
  end

  context 'without the diagnostic (flag off)' do
    before { populate_data(diagnostic: false) }

    it 'silently returns the default tenant data when a captured relation is accessed outside its switch block' do
      captured = Apartment::Tenant.switch('acme') { Widget.all }
      expect(captured.pluck(:name)).to(eq(['in_default']))
    end

    it 'does not log the fallback' do
      Apartment::Tenant.switch('acme') { Widget.all }.pluck(:name)
      expect(log_io.string).not_to(match(/\[Apartment\] tenant=nil/))
    end
  end

  context 'with the diagnostic (flag on)' do
    before { populate_data(diagnostic: true) }

    it 'still silently returns the default tenant data (diagnostic is passive)' do
      captured = Apartment::Tenant.switch('acme') { Widget.all }
      expect(captured.pluck(:name)).to(eq(['in_default']))
    end

    it 'emits a debug log line tagged [Apartment] tenant=nil with caller info' do
      Apartment::Tenant.switch('acme') { Widget.all }.pluck(:name)
      expect(log_io.string).to(match(/DEBUG/))
      expect(log_io.string).to(match(/\[Apartment\] tenant=nil/))
      # Caller should resolve to THIS spec file, not to an AR internal
      # frame. Verifies the GEM_ROOT / Rails-core filter is doing the
      # right thing under realistic AR call stacks.
      expect(log_io.string).to(match(%r{Caller=.*log_default_tenant_fallback_spec\.rb:\d+}))
    end

    it 'dedupes per call site: repeated access at the same line logs once' do
      captured = Apartment::Tenant.switch('acme') { Widget.all }
      5.times { captured.pluck(:name) }
      expect(log_io.string.scan('[Apartment] tenant=nil').size).to(eq(1))
    end

    it 'does not log when access is inside an explicit Tenant.switch' do
      Apartment::Tenant.switch('acme') { Widget.pluck(:name) }
      Apartment::Tenant.switch(V4IntegrationHelper.default_tenant) { Widget.pluck(:name) }
      expect(log_io.string).not_to(match(/\[Apartment\] tenant=nil/))
    end
  end
end
