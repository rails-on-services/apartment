# frozen_string_literal: true

require 'spec_helper'
require 'rake'

describe 'apartment rake tasks', database: :postgresql do
  before do
    @rake = Rake::Application.new
    Rake.application = @rake
    Dummy::Application.load_tasks

    # rails tasks running F up the schema...
    Rake::Task.define_task('db:migrate')
    Rake::Task.define_task('db:seed')
    Rake::Task.define_task('db:rollback')
    Rake::Task.define_task('db:migrate:up')
    Rake::Task.define_task('db:migrate:down')
    Rake::Task.define_task('db:migrate:redo')

    Apartment.configure do |config|
      config.use_schemas = true
      config.excluded_models = ['Company']
      config.tenant_names = -> { Company.pluck(:database) }
    end
    Apartment::Tenant.reload!(config)

    # fix up table name of shared/excluded models
    Company.table_name = 'public.companies'
  end

  after { Rake.application = nil }

  context 'with x number of databases' do
    let(:x) { rand(1..5) } # random number of dbs to create
    let(:db_names) { Array.new(x).map { Apartment::Test.next_db } }
    let!(:company_count) { db_names.length }

    before do
      db_names.collect do |db_name|
        Apartment::Tenant.create(db_name)
        Company.create database: db_name
      end
    end

    after do
      db_names.each { |db| Apartment::Tenant.drop(db) }
      Company.delete_all
    end

    describe 'apartment:seed' do
      it 'should seed all databases' do
        expect(Apartment::Tenant).to receive(:seed).exactly(company_count).times

        @rake['apartment:seed'].invoke
      end
    end
  end
end
