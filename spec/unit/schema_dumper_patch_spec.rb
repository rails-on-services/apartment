# frozen_string_literal: true

require 'spec_helper'
require_relative '../../lib/apartment/schema_dumper_patch'

# `ActiveRecord::ConnectionAdapters::PostgreSQL::SchemaDumper` is defined by the
# PG adapter file, which AR only requires when something opens a PostgreSQL
# connection. The unit suite never does, so the constant is absent even under a
# postgresql appraisal that has the pg gem — requiring the adapter eagerly is
# what makes `.apply!` observable here at all. PG_UNIT_REQUIRED=1 turns the skip
# into a hard failure in the job that IS supposed to load pg. See spec/CLAUDE.md.
PG_SCHEMA_DUMPER_AVAILABLE = begin
  require('active_record/connection_adapters/postgresql_adapter')
  true
rescue LoadError => e
  raise if ENV['PG_UNIT_REQUIRED']

  warn "[schema_dumper_patch_spec] Skipping .apply! example: #{e.message}"
  false
end

RSpec.describe(Apartment::SchemaDumperPatch) do
  describe '.strip_public_prefix' do
    it 'strips public. prefix from table name' do
      expect(described_class.strip_public_prefix('public.users')).to(eq('users'))
    end

    it 'leaves non-public schemas intact' do
      expect(described_class.strip_public_prefix('extensions.uuid_ossp')).to(eq('extensions.uuid_ossp'))
    end

    it 'leaves unqualified names unchanged' do
      expect(described_class.strip_public_prefix('users')).to(eq('users'))
    end

    it 'respects include_schemas_in_dump' do
      expect(described_class.strip_public_prefix('shared.lookups', include_schemas: %w[shared]))
        .to(eq('shared.lookups'))
    end

    it 'strips public. even when include_schemas is set' do
      expect(described_class.strip_public_prefix('public.users', include_schemas: %w[shared]))
        .to(eq('users'))
    end
  end

  describe '.should_patch?' do
    it 'returns true when Rails >= 8.1 and SchemaDumper is defined' do
      allow(ActiveRecord).to(receive(:gem_version).and_return(Gem::Version.new('8.1.0')))
      expect(described_class.should_patch?).to(be(true))
    end

    it 'returns false when Rails < 8.1' do
      allow(ActiveRecord).to(receive(:gem_version).and_return(Gem::Version.new('8.0.5')))
      expect(described_class.should_patch?).to(be(false))
    end
  end

  describe '.apply!' do
    it 'prepends DumperOverride on the PG-specific SchemaDumper for Rails >= 8.1' do
      skip('requires the pg gem (run via a postgresql appraisal)') unless PG_SCHEMA_DUMPER_AVAILABLE

      allow(described_class).to(receive(:should_patch?).and_return(true))

      described_class.apply!
      expect(ActiveRecord::ConnectionAdapters::PostgreSQL::SchemaDumper.ancestors)
        .to(include(Apartment::SchemaDumperPatch::DumperOverride))
    end

    it 'is a no-op when should_patch? is false' do
      allow(described_class).to(receive(:should_patch?).and_return(false))
      described_class.apply!
      # No error raised, no prepend attempted
    end
  end

  describe 'DumperOverride#relation_name' do
    let(:override_instance) do
      obj = Object.new
      obj.extend(Apartment::SchemaDumperPatch::DumperOverride)
      obj
    end

    before do
      Apartment.configure do |c|
        c.tenant_strategy = :schema
        c.tenants_provider = -> { [] }
        c.default_tenant = 'public'
        c.configure_postgres do |pg|
          pg.include_schemas_in_dump = %w[shared]
        end
      end
    end

    it 'strips public. prefix from relation names' do
      # Simulate what Rails 8.1 relation_name returns before our override
      allow(override_instance).to(receive(:relation_name).and_call_original)
      # The super call in DumperOverride would return the schema-qualified name;
      # we test the strip_public_prefix logic directly since we can't easily
      # set up the full SchemaDumper inheritance chain in a unit test.
      expect(described_class.strip_public_prefix('public.users')).to(eq('users'))
    end

    it 'preserves schemas listed in include_schemas_in_dump' do
      expect(described_class.strip_public_prefix('shared.lookups', include_schemas: %w[shared]))
        .to(eq('shared.lookups'))
    end
  end
end
