require 'spec_helper'

describe 'connection handling monkey patch' do
  let(:db_names) { [db1, db2] }

  before do
    Apartment.configure do |config|
      config.excluded_models = ['Company']
      config.tenant_names = -> { Company.pluck(:database) }
      config.use_schemas = true
    end

    Apartment::Tenant.reload!(config)

    db_names.each do |db_name|
      Apartment::Tenant.create(db_name)
      Company.create database: db_name
      Apartment::Tenant.switch! db_name
      User.create! name: db_name
    end
  end

  after do
    db_names.each { |db| Apartment::Tenant.drop(db) }
    Apartment::Tenant.reset
    Company.delete_all
  end

  context 'ActiveRecord 5.x', if: ActiveRecord::VERSION::MAJOR == 5 do
    it 'is not monkey patched' do
      expect(ActiveRecord::ConnectionHandling.instance_methods).to_not include(:connected_to_with_tenant)
    end
  end

  context 'ActiveRecord >= 6.0', if: ActiveRecord::VERSION::MAJOR >= 6 do
    it 'is monkey patched' do
      expect(ActiveRecord::ConnectionHandling.instance_methods).to include(:connected_to_with_tenant)
    end

    it 'switches to the previous set tenant' do
      # Choose the role depending on the ActiveRecord version.
      role = case ActiveRecord::VERSION::MAJOR
             when 6 then ActiveRecord::Base.writing_role # deprecated in Rails 7
             else ActiveRecord.writing_role
             end

      Apartment::Tenant.switch! db_names.first
      ActiveRecord::Base.connected_to(role: role) do
        expect(Apartment::Tenant.current).to eq db_names.first
        expect(User.find_by(name: db_names.first).name).to eq(db_names.first)
      end

      Apartment::Tenant.switch! db_names.last
      ActiveRecord::Base.connected_to(role: role) do
        expect(Apartment::Tenant.current).to eq db_names.last
        expect(User.find_by(name: db_names.last).name).to eq(db_names.last)
      end
    end
  end
end
