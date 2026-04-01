# frozen_string_literal: true

require 'spec_helper'
require_relative '../../lib/apartment/schema_cache'

RSpec.describe(Apartment::SchemaCache) do
  describe '.cache_path_for' do
    it 'returns db/schema_cache_<tenant>.yml' do
      path = described_class.cache_path_for('acme')
      expect(path).to(end_with('db/schema_cache_acme.yml'))
    end
  end

  describe '.dump' do
    it 'switches to tenant and dumps schema cache' do
      schema_cache = double('schema_cache')
      connection = double('connection', schema_cache: schema_cache)
      allow(Apartment::Tenant).to(receive(:switch).and_yield)
      allow(ActiveRecord::Base).to(receive(:connection).and_return(connection))
      allow(schema_cache).to(receive(:dump_to))

      path = described_class.dump('acme')

      expect(Apartment::Tenant).to(have_received(:switch).with('acme'))
      expect(schema_cache).to(have_received(:dump_to).with(path))
      expect(path).to(end_with('schema_cache_acme.yml'))
    end
  end

  describe '.dump_all' do
    it 'dumps for each tenant from provider' do
      Apartment.configure do |c|
        c.tenant_strategy = :schema
        c.tenants_provider = -> { %w[t1 t2] }
        c.default_tenant = 'public'
      end
      allow(described_class).to(receive(:dump).and_return('path'))

      described_class.dump_all

      expect(described_class).to(have_received(:dump).with('t1'))
      expect(described_class).to(have_received(:dump).with('t2'))
    end
  end
end
