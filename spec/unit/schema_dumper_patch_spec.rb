# frozen_string_literal: true

require 'spec_helper'
require_relative '../../lib/apartment/schema_dumper_patch'

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
end
