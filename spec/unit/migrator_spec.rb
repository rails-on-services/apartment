# frozen_string_literal: true

require 'spec_helper'
require 'apartment/migrator'

describe Apartment::Migrator do
  let(:tenant) { Apartment::Test.next_db }

  # Don't need a real switch here, just testing behaviour
  before { allow(Apartment::Tenant.adapter).to(receive(:connect_to_new)) }

  context 'with ActiveRecord above or equal to 6.1.0' do
    describe '::migrate' do
      it 'switches and migrates' do
        expect(Apartment::Tenant).to(receive(:switch).with(tenant).and_call_original)
        expect_any_instance_of(ActiveRecord::MigrationContext).to(receive(:migrate))

        described_class.migrate(tenant)
      end
    end

    describe '::run' do
      it 'switches and runs' do
        expect(Apartment::Tenant).to(receive(:switch).with(tenant).and_call_original)
        expect_any_instance_of(ActiveRecord::MigrationContext).to(receive(:run).with(:up, 1234))

        described_class.run(:up, tenant, 1234)
      end
    end

    describe '::rollback' do
      it 'switches and rolls back' do
        expect(Apartment::Tenant).to(receive(:switch).with(tenant).and_call_original)
        expect_any_instance_of(ActiveRecord::MigrationContext).to(receive(:rollback).with(2))

        described_class.rollback(tenant, 2)
      end
    end

    describe '::rollback_to_version' do
      let(:connection) { double('Connection') }
      let(:migration_context) { double('MigrationContext') }

      before do
        # Stub the switch to yield without actual tenant switching
        allow(Apartment::Tenant).to(receive(:switch).with(tenant).and_yield)
        allow(ActiveRecord::Base).to(receive(:connection).and_return(connection))
        allow(connection).to(receive(:quote).with('20240101000000').and_return("'20240101000000'"))
      end

      it 'switches to tenant' do
        expect(Apartment::Tenant).to(receive(:switch).with(tenant))
        allow(connection).to(receive(:select_values).and_return([]))

        described_class.rollback_to_version(tenant, '20240101000000')
      end

      it 'returns empty array when no migrations to rollback' do
        allow(connection).to(receive(:select_values).and_return([]))

        result = described_class.rollback_to_version(tenant, '20240101000000')
        expect(result).to(eq([]))
      end

      it 'rolls back each migration in reverse order' do
        migrations = %w[20240103000000 20240102000000]
        allow(connection).to(receive(:select_values).and_return(migrations))

        if ActiveRecord.version >= Gem::Version.new('7.2.0')
          allow(ActiveRecord::Base).to(receive(:connection_pool)
            .and_return(double(migration_context: migration_context)))
        else
          allow(connection).to(receive(:migration_context).and_return(migration_context))
        end

        expect(migration_context).to(receive(:run).with(:down, 20_240_103_000_000).ordered)
        expect(migration_context).to(receive(:run).with(:down, 20_240_102_000_000).ordered)

        result = described_class.rollback_to_version(tenant, '20240101000000')
        expect(result).to(eq([20_240_103_000_000, 20_240_102_000_000]))
      end
    end
  end
end
