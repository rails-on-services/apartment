# frozen_string_literal: true

require 'spec_helper'

# QueryLogs requires ActiveRecord 7.1+.
return unless defined?(ActiveRecord::QueryLogs)

RSpec.describe('sql_query_tags Railtie wiring') do
  after do
    # Clean up: remove :tenant from tags and taggings if we added it.
    if ActiveRecord::QueryLogs.tags.include?(:tenant)
      ActiveRecord::QueryLogs.tags = ActiveRecord::QueryLogs.tags - [:tenant]
    end
    if ActiveRecord::QueryLogs.taggings.key?(:tenant)
      ActiveRecord::QueryLogs.taggings = ActiveRecord::QueryLogs.taggings.except(:tenant)
    end
  end

  describe 'Apartment.activate_sql_query_tags!' do
    context 'when sql_query_tags is true' do
      before do
        Apartment.configure do |config|
          config.tenant_strategy = :schema
          config.tenants_provider = -> { [] }
          config.sql_query_tags = true
        end
      end

      it 'registers a :tenant tagging that reads Apartment::Current.tenant' do
        Apartment.activate_sql_query_tags!

        expect(ActiveRecord::QueryLogs.taggings).to(have_key(:tenant))

        Apartment::Current.tenant = 'acme'
        expect(ActiveRecord::QueryLogs.taggings[:tenant].call).to(eq('acme'))
      ensure
        Apartment::Current.reset
      end

      it 'adds :tenant to the active tags list' do
        Apartment.activate_sql_query_tags!

        expect(ActiveRecord::QueryLogs.tags).to(include(:tenant))
      end

      it 'does not duplicate :tenant if called twice' do
        Apartment.activate_sql_query_tags!
        Apartment.activate_sql_query_tags!

        expect(ActiveRecord::QueryLogs.tags.count(:tenant)).to(eq(1))
      end
    end

    context 'when sql_query_tags is false' do
      before do
        Apartment.configure do |config|
          config.tenant_strategy = :schema
          config.tenants_provider = -> { [] }
          config.sql_query_tags = false
        end
      end

      it 'does not register a :tenant tagging' do
        Apartment.activate_sql_query_tags!

        expect(ActiveRecord::QueryLogs.taggings).not_to(have_key(:tenant))
      end
    end
  end
end
