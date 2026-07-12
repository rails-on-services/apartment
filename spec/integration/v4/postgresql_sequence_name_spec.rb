# frozen_string_literal: true

require 'spec_helper'
require_relative 'support'

# Regression spec for the v3->v4 sequence-name regression: ActiveRecord
# memoizes Model.sequence_name once per class, process-wide, resolved
# schema-qualified on whichever tenant's connection touches it first.
# activerecord-import renders that memoized value into a literal
# nextval(...), so every tenant then draws ids from the first tenant's
# sequence. The patch keeps the memoized value schema-agnostic.
RSpec.describe('v4 PostgreSQL sequence_name resolution', :integration,
               skip: (V4_INTEGRATION_AVAILABLE && V4IntegrationHelper.postgresql? ? false : 'requires PostgreSQL')) do
  include V4IntegrationHelper

  let(:tmp_dir) { Dir.mktmpdir('apartment_pg_seq') }
  let(:created_tenants) { [] }

  before do
    V4IntegrationHelper.ensure_test_database!
    config = V4IntegrationHelper.establish_default_connection!(tmp_dir: tmp_dir)

    Apartment.configure do |c|
      c.tenant_strategy = :schema
      c.tenants_provider = -> { [] }
      c.default_tenant = 'public'
      c.check_pending_migrations = false
    end

    Apartment.adapter = V4IntegrationHelper.build_adapter(config)
    Apartment.activate!

    stub_const('SequenceWidget', Class.new(ActiveRecord::Base) do
      self.table_name = 'sequence_widgets'
    end)

    %w[seq_a seq_b].each do |name|
      Apartment.adapter.create(name)
      created_tenants << name
      Apartment::Tenant.switch(name) do
        ActiveRecord::Base.connection.create_table(:sequence_widgets, force: true) do |t|
          t.string(:name)
        end
      end
    end

    # Seed each tenant's sequence to a distinct range so "which sequence
    # produced this id" is unambiguous (fresh sequences both sit at 1).
    { 'seq_a' => 1_000, 'seq_b' => 2_000 }.each do |schema, value|
      ActiveRecord::Base.connection.select_value(
        %(SELECT setval('"#{schema}".sequence_widgets_id_seq', #{value}))
      )
    end
  end

  after do
    V4IntegrationHelper.cleanup_tenants!(created_tenants, Apartment.adapter)
    Apartment.clear_config
    Apartment::Current.reset
  end

  def last_value(schema, sequence: 'sequence_widgets_id_seq')
    ActiveRecord::Base.connection.select_value(
      %(SELECT last_value FROM "#{schema}"."#{sequence}")
    ).to_i
  end

  # Emulates activerecord-import's primary-key prefetch: it renders the
  # memoized Model.sequence_name into a literal nextval() on the model's
  # own connection (import.rb ~1042 + its postgresql adapter).
  def prefetch_id(model)
    model.with_connection do |conn|
      conn.select_value("SELECT nextval('#{model.sequence_name}')").to_i
    end
  end

  it 'prepends the patch onto the PostgreSQL adapter' do
    Apartment::Tenant.switch('seq_a') do
      adapter_class = SequenceWidget.with_connection(&:class)
      expect(adapter_class.ancestors).to(include(Apartment::Patches::PostgresqlSequenceName))
    end
  end

  it 'memoizes a schema-agnostic sequence_name' do
    name = Apartment::Tenant.switch('seq_a') { SequenceWidget.sequence_name }
    expect(name).to(eq('sequence_widgets_id_seq'))
  end

  it 'draws prefetched ids from the current tenant even when another tenant resolved sequence_name first' do
    # The poisoning step: memoize Model.sequence_name inside seq_a.
    Apartment::Tenant.switch('seq_a') { SequenceWidget.sequence_name }

    drawn = Apartment::Tenant.switch('seq_b') { prefetch_id(SequenceWidget) }

    expect(drawn).to(eq(2_001))                # from seq_b's range
    expect(last_value('seq_a')).to(eq(1_000))  # donor untouched
    expect(last_value('seq_b')).to(eq(2_001))  # target advanced
  end

  context 'with a pinned model' do
    before do
      # Same-named table in BOTH public and seq_a: the sharp version of the
      # excluded-models guarantee -- the pinned model must draw from public
      # even while switched into a tenant that has an identically-named
      # table. (PG schema strategy shares the tenant connection for pinned
      # models and relies on their public.-qualified names; the patch must
      # preserve that qualification.)
      ActiveRecord::Base.connection.create_table(:pinned_settings, force: true) do |t|
        t.string(:key)
      end
      ActiveRecord::Base.connection.select_value(
        %(SELECT setval('public.pinned_settings_id_seq', 500))
      )

      Apartment::Tenant.switch('seq_a') do
        ActiveRecord::Base.connection.create_table(:pinned_settings, force: true) do |t|
          t.string(:key)
        end
        ActiveRecord::Base.connection.select_value(
          %(SELECT setval('"seq_a".pinned_settings_id_seq', 900))
        )
      end

      stub_const('PinnedSetting', Class.new(ActiveRecord::Base) do
        self.table_name = 'pinned_settings'
        include Apartment::Model

        pin_tenant
      end)
      Apartment.adapter.process_pinned_models
    end

    after do
      ActiveRecord::Base.connection.drop_table(:pinned_settings, if_exists: true)
    end

    it 'draws pinned-model ids from the default tenant even inside a tenant switch' do
      drawn = Apartment::Tenant.switch('seq_a') { prefetch_id(PinnedSetting) }

      expect(drawn).to(eq(501)) # public's range
      expect(last_value('seq_a', sequence: 'pinned_settings_id_seq')).to(eq(900)) # tenant copy untouched
    end

    # The inverse order, and the one that actually happens in production: a
    # pinned model is typically touched at boot (eager load, first request)
    # while still on the DEFAULT pool, whose current_schema IS the default
    # tenant. Stripping there would leave an unqualified sequence name that
    # later re-resolves against a TENANT's search_path -- drawing ids from
    # the tenant's stale copy of the pinned table's sequence. v3 guarded this
    # by force-qualifying excluded models to the default tenant.
    it 'keeps the pinned-model sequence qualified when resolved on the default tenant first' do
      PinnedSetting.sequence_name # memoize while on the default pool (no switch)

      drawn = Apartment::Tenant.switch('seq_a') { prefetch_id(PinnedSetting) }

      expect(PinnedSetting.sequence_name).to(eq('public.pinned_settings_id_seq'))
      expect(drawn).to(eq(501)) # public's range, not seq_a's 901
      expect(last_value('seq_a', sequence: 'pinned_settings_id_seq')).to(eq(900))
    end
  end
end
