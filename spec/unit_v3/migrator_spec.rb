# frozen_string_literal: true

require 'spec_helper'
require 'apartment/migrator'

describe Apartment::Migrator do
  let(:tenant) { Apartment::Test.next_db }
  let(:connection_pool) { ActiveRecord::Base.connection_pool }

  # Don't need a real switch here, just testing behaviour
  before { allow(Apartment::Tenant.adapter).to(receive(:connect_to_new)) }

  context 'with ActiveRecord above or equal to 6.1.0' do
    describe '::migrate' do
      it 'switches and migrates' do
        expect(Apartment::Tenant).to(receive(:switch).with(tenant).and_call_original)
        expect_any_instance_of(ActiveRecord::MigrationContext).to(receive(:migrate))

        described_class.migrate(tenant)
      end

      it 'pins connection for entire migration to ensure search_path consistency' do
        expect(connection_pool).to(receive(:with_connection).and_call_original)
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

      it 'pins connection for entire operation to ensure search_path consistency' do
        expect(connection_pool).to(receive(:with_connection).and_call_original)
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

      it 'pins connection for entire rollback to ensure search_path consistency' do
        expect(connection_pool).to(receive(:with_connection).and_call_original)
        expect_any_instance_of(ActiveRecord::MigrationContext).to(receive(:rollback).with(2))

        described_class.rollback(tenant, 2)
      end
    end
  end
end
