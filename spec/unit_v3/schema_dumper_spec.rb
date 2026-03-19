# frozen_string_literal: true

require 'spec_helper'
require 'apartment/tasks/schema_dumper'

describe Apartment::Tasks::SchemaDumper do
  before do
    Apartment.reset
    allow(Apartment).to(receive(:default_tenant).and_return('public'))
  end

  describe '.dump_if_enabled' do
    context 'when Rails dump_schema_after_migration is false' do
      before do
        allow(ActiveRecord::Base).to(receive(:dump_schema_after_migration).and_return(false))
      end

      it 'does not dump schema' do
        expect(described_class).not_to(receive(:find_schema_dump_config))
        described_class.dump_if_enabled
      end
    end

    context 'when Rails dump_schema_after_migration is true' do
      let(:db_config) { double('DatabaseConfig', configuration_hash: { schema_dump: true }) }

      before do
        allow(ActiveRecord::Base).to(receive(:dump_schema_after_migration).and_return(true))
        allow(described_class).to(receive(:find_schema_dump_config).and_return(db_config))
        allow(Apartment::Tenant).to(receive(:switch).and_yield)
        allow(Rake::Task).to(receive(:task_defined?).with('db:schema:dump').and_return(true))
        allow(Rake::Task).to(receive(:[]).with('db:schema:dump')
          .and_return(double(reenable: nil, invoke: nil)))
        allow(Rails.logger).to(receive(:info))
      end

      it 'switches to default tenant and dumps schema' do
        expect(Apartment::Tenant).to(receive(:switch).with('public'))
        described_class.dump_if_enabled
      end

      it 'logs schema dump progress' do
        expect(Rails.logger).to(receive(:info).with(/Dumping schema/))
        expect(Rails.logger).to(receive(:info).with(/Schema dump completed/))
        described_class.dump_if_enabled
      end

      context 'when schema_dump is false in config' do
        let(:db_config) { double('DatabaseConfig', configuration_hash: { schema_dump: false }) }

        it 'does not dump schema' do
          expect(Rake::Task).not_to(receive(:[]).with('db:schema:dump'))
          described_class.dump_if_enabled
        end
      end

      context 'when db_config is nil' do
        before { allow(described_class).to(receive(:find_schema_dump_config).and_return(nil)) }

        it 'does not dump schema' do
          expect(Apartment::Tenant).not_to(receive(:switch))
          described_class.dump_if_enabled
        end
      end

      context 'when dump fails' do
        before do
          allow(Apartment::Tenant).to(receive(:switch).and_raise(StandardError.new('Test error')))
        end

        it 'catches the error and logs a warning' do
          expect(Rails.logger).to(receive(:warn).with(/Schema dump failed: Test error/))
          described_class.dump_if_enabled
        end
      end
    end
  end

  describe '.find_schema_dump_config' do
    let(:configs) { [] }

    before do
      allow(ActiveRecord::Base).to(receive(:configurations)
        .and_return(double(configs_for: configs)))
      allow(Rails).to(receive(:env).and_return('test'))
    end

    context 'when database_tasks config exists' do
      let(:primary_config) do
        double('DatabaseConfig', name: 'primary', database_tasks?: false, replica?: false)
      end
      let(:migration_config) do
        double('DatabaseConfig', name: 'migration', database_tasks?: true, replica?: false)
      end
      let(:configs) { [primary_config, migration_config] }

      it 'returns config with database_tasks: true' do
        expect(described_class.send(:find_schema_dump_config)).to(eq(migration_config))
      end
    end

    context 'when no database_tasks config exists' do
      let(:primary_config) do
        double('DatabaseConfig', name: 'primary', database_tasks?: false, replica?: false)
      end
      let(:configs) { [primary_config] }

      it 'falls back to primary' do
        expect(described_class.send(:find_schema_dump_config)).to(eq(primary_config))
      end
    end

    context 'when replica config exists' do
      let(:replica_config) do
        double('DatabaseConfig', name: 'replica', database_tasks?: true, replica?: true)
      end
      let(:primary_config) do
        double('DatabaseConfig', name: 'primary', database_tasks?: false, replica?: false)
      end
      let(:configs) { [replica_config, primary_config] }

      it 'excludes replica configs' do
        expect(described_class.send(:find_schema_dump_config)).to(eq(primary_config))
      end
    end
  end
end
