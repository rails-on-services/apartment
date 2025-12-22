# frozen_string_literal: true

require 'spec_helper'
require 'rake'
require 'apartment/tasks/enhancements'

describe Apartment::RakeTaskEnhancer do
  let(:rake) { Rake::Application.new }

  before do
    Rake.application = rake
    Apartment.reset

    # Define base db tasks
    Rake::Task.define_task('db:migrate')
    Rake::Task.define_task('db:rollback')
    Rake::Task.define_task('db:migrate:up')
    Rake::Task.define_task('db:migrate:down')
    Rake::Task.define_task('db:migrate:redo')
    Rake::Task.define_task('db:seed')
    Rake::Task.define_task('db:drop')

    # Define apartment tasks
    Rake::Task.define_task('apartment:migrate')
    Rake::Task.define_task('apartment:rollback')
    Rake::Task.define_task('apartment:migrate:up')
    Rake::Task.define_task('apartment:migrate:down')
    Rake::Task.define_task('apartment:migrate:redo')
    Rake::Task.define_task('apartment:seed')
    Rake::Task.define_task('apartment:drop')
  end

  after do
    Rake.application = nil
  end

  describe '.enhance!' do
    context 'when db_migrate_tenants is false' do
      before { allow(Apartment).to(receive(:db_migrate_tenants).and_return(false)) }

      it 'does not enhance any tasks' do
        expect(described_class).not_to(receive(:enhance_base_tasks!))
        expect(described_class).not_to(receive(:enhance_namespaced_tasks!))
        described_class.enhance!
      end
    end

    context 'when db_migrate_tenants is true' do
      before { allow(Apartment).to(receive(:db_migrate_tenants).and_return(true)) }

      it 'enhances base tasks' do
        expect(described_class).to(receive(:enhance_base_tasks!).and_call_original)
        described_class.enhance!
      end

      it 'enhances namespaced tasks' do
        expect(described_class).to(receive(:enhance_namespaced_tasks!).and_call_original)
        described_class.enhance!
      end
    end
  end

  describe '.database_names_with_tasks' do
    context 'when Rails is not defined' do
      before do
        hide_const('Rails')
      end

      it 'returns empty array' do
        expect(described_class.send(:database_names_with_tasks)).to(eq([]))
      end
    end

    context 'when Rails is defined with multiple databases' do
      def stub_database_configs(configs)
        allow(Rails).to(receive(:env).and_return('test'))
        allow(ActiveRecord::Base).to(receive(:configurations)
          .and_return(double(configs_for: configs)))
      end

      it 'returns all database names with database_tasks enabled' do
        configs = [
          double('DatabaseConfig', name: 'primary', database_tasks?: true, replica?: false),
          double('DatabaseConfig', name: 'secondary', database_tasks?: true, replica?: false),
        ]
        stub_database_configs(configs)

        expect(described_class.send(:database_names_with_tasks)).to(eq(%w[primary secondary]))
      end

      it 'excludes replica databases' do
        configs = [
          double('DatabaseConfig', name: 'primary', database_tasks?: true, replica?: false),
          double('DatabaseConfig', name: 'replica', database_tasks?: true, replica?: true),
        ]
        stub_database_configs(configs)

        expect(described_class.send(:database_names_with_tasks)).to(eq(['primary']))
      end

      it 'excludes databases with database_tasks: false' do
        configs = [
          double('DatabaseConfig', name: 'primary', database_tasks?: true, replica?: false),
          double('DatabaseConfig', name: 'analytics', database_tasks?: false, replica?: false),
        ]
        stub_database_configs(configs)

        expect(described_class.send(:database_names_with_tasks)).to(eq(['primary']))
      end
    end

    context 'when configuration raises an error' do
      before do
        allow(Rails).to(receive(:env).and_return('test'))
        allow(ActiveRecord::Base).to(receive(:configurations).and_raise(StandardError.new('Test error')))
      end

      it 'returns empty array' do
        expect(described_class.send(:database_names_with_tasks)).to(eq([]))
      end
    end
  end

  describe '.enhance_namespaced_tasks!' do
    before do
      allow(Apartment).to(receive(:db_migrate_tenants).and_return(true))
      allow(Rails).to(receive(:env).and_return('test'))
    end

    context 'when namespaced tasks exist' do
      let(:primary_config) do
        double('DatabaseConfig', name: 'primary', database_tasks?: true, replica?: false)
      end
      let(:configs) { [primary_config] }

      before do
        allow(ActiveRecord::Base).to(receive(:configurations)
          .and_return(double(configs_for: configs)))

        # Define namespaced tasks
        Rake::Task.define_task('db:migrate:primary')
        Rake::Task.define_task('db:rollback:primary')
        Rake::Task.define_task('db:migrate:up:primary')
        Rake::Task.define_task('db:migrate:down:primary')
        Rake::Task.define_task('db:migrate:redo:primary')
      end

      it 'enhances db:migrate:primary to invoke apartment:migrate' do
        described_class.enhance!

        expect(Rake::Task['apartment:migrate']).to(receive(:invoke))
        Rake::Task['db:migrate:primary'].invoke
      end

      it 'enhances db:rollback:primary to invoke apartment:rollback' do
        described_class.enhance!

        expect(Rake::Task['apartment:rollback']).to(receive(:invoke))
        Rake::Task['db:rollback:primary'].invoke
      end

      it 'enhances db:migrate:up:primary to invoke apartment:migrate:up' do
        described_class.enhance!

        expect(Rake::Task['apartment:migrate:up']).to(receive(:invoke))
        Rake::Task['db:migrate:up:primary'].invoke
      end

      it 'enhances db:migrate:down:primary to invoke apartment:migrate:down' do
        described_class.enhance!

        expect(Rake::Task['apartment:migrate:down']).to(receive(:invoke))
        Rake::Task['db:migrate:down:primary'].invoke
      end

      it 'enhances db:migrate:redo:primary to invoke apartment:migrate:redo' do
        described_class.enhance!

        expect(Rake::Task['apartment:migrate:redo']).to(receive(:invoke))
        Rake::Task['db:migrate:redo:primary'].invoke
      end
    end

    context 'when namespaced tasks do not exist' do
      let(:primary_config) do
        double('DatabaseConfig', name: 'primary', database_tasks?: true, replica?: false)
      end
      let(:configs) { [primary_config] }

      before do
        allow(ActiveRecord::Base).to(receive(:configurations)
          .and_return(double(configs_for: configs)))
        # NOTE: we don't define namespaced tasks here
      end

      it 'does not raise an error' do
        expect { described_class.enhance! }.not_to(raise_error)
      end
    end

    context 'with multiple databases' do
      let(:primary_config) do
        double('DatabaseConfig', name: 'primary', database_tasks?: true, replica?: false)
      end
      let(:secondary_config) do
        double('DatabaseConfig', name: 'secondary', database_tasks?: true, replica?: false)
      end
      let(:configs) { [primary_config, secondary_config] }

      before do
        allow(ActiveRecord::Base).to(receive(:configurations)
          .and_return(double(configs_for: configs)))

        # Define namespaced tasks for both databases
        Rake::Task.define_task('db:migrate:primary')
        Rake::Task.define_task('db:migrate:secondary')
        Rake::Task.define_task('db:rollback:primary')
        Rake::Task.define_task('db:rollback:secondary')
      end

      it 'enhances tasks for all databases' do
        described_class.enhance!

        # Test primary
        expect(Rake::Task['apartment:migrate']).to(receive(:invoke).twice)
        Rake::Task['db:migrate:primary'].invoke
        Rake::Task['db:migrate:secondary'].invoke
      end
    end
  end

  describe 'base task enhancement' do
    before do
      allow(Apartment).to(receive(:db_migrate_tenants).and_return(true))
      allow(described_class).to(receive(:database_names_with_tasks).and_return([]))
    end

    it 'enhances db:migrate to invoke apartment:migrate' do
      described_class.enhance!

      expect(Rake::Task['apartment:migrate']).to(receive(:invoke))
      Rake::Task['db:migrate'].invoke
    end

    it 'enhances db:rollback to invoke apartment:rollback' do
      described_class.enhance!

      expect(Rake::Task['apartment:rollback']).to(receive(:invoke))
      Rake::Task['db:rollback'].invoke
    end

    it 'enhances db:seed to invoke apartment:seed' do
      described_class.enhance!

      expect(Rake::Task['apartment:seed']).to(receive(:invoke))
      Rake::Task['db:seed'].invoke
    end

    it 'enhances db:drop with apartment:drop as prerequisite' do
      described_class.enhance!

      expect(Rake::Task['db:drop'].prerequisites).to(include('apartment:drop'))
    end
  end
end
