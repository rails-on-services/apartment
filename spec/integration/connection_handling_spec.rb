# frozen_string_literal: true

require 'spec_helper'

describe 'connection handling monkey patch' do
  let(:db_name) { db1 }

  before do
    Apartment.configure do |config|
      config.excluded_models = ['Company']
      config.tenant_names = -> { Company.pluck(:database) }
      config.use_schemas = true
    end

    Apartment::Tenant.reload!(config)

    Apartment::Tenant.create(db_name)
    Company.create database: db_name
    Apartment::Tenant.switch! db_name
    User.create! name: db_name
  end

  after do
    Apartment::Tenant.drop(db_name)
    Apartment::Tenant.reset
    Company.delete_all
  end

  context 'when ActiveRecord >= 6.0', if: ActiveRecord::VERSION::MAJOR >= 6 do
    let(:role) do
      # Choose the role depending on the ActiveRecord version.
      case ActiveRecord::VERSION::MAJOR
      when 6 then ActiveRecord::Base.writing_role # deprecated in Rails 7
      else ActiveRecord.writing_role
      end
    end

    it 'is monkey patched' do
      expect(ActiveRecord::ConnectionHandling.instance_methods).to include(:connected_to_with_tenant)
    end

    it 'switches to the previous set tenant' do
      Apartment::Tenant.switch! db_name
      ActiveRecord::Base.connected_to(role: role) do
        expect(Apartment::Tenant.current).to eq db_name
        expect(User.find_by(name: db_name).name).to eq(db_name)
      end
    end
  end
end
