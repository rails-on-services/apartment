# frozen_string_literal: true

if defined?(JRUBY_VERSION) && ENV['DATABASE_ENGINE'] == 'mysql'

  require 'spec_helper'
  require 'apartment/adapters/jdbc_mysql_adapter'

  describe Apartment::Adapters::JDBCMysqlAdapter, database: :mysql do
    subject(:adapter) { Apartment::Tenant.adapter }

    def tenant_names
      ActiveRecord::Base.connection.execute('SELECT SCHEMA_NAME FROM information_schema.schemata').collect do |row|
        row['SCHEMA_NAME']
      end
    end

    let(:default_tenant) { subject.switch { ActiveRecord::Base.connection.current_database } }

    it_behaves_like 'a generic apartment adapter callbacks'
    it_behaves_like 'a generic apartment adapter'
    it_behaves_like 'a connection based apartment adapter'
  end
end
