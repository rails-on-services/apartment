# frozen_string_literal: true

require 'spec_helper'

# Pure-logic spec: the module only needs `super` (the Rails-resolved,
# possibly schema-qualified sequence name) and `current_schema` (the
# connection's own schema), so a fake adapter class exercises every
# branch without a database.
RSpec.describe(Apartment::Patches::PostgresqlSequenceName) do
  let(:adapter_class) do
    Class.new do
      prepend(Apartment::Patches::PostgresqlSequenceName)

      def initialize(resolved:, schema:)
        @resolved = resolved
        @schema = schema
      end

      def default_sequence_name(_table, _column)
        @resolved
      end

      def current_schema
        @schema
      end
    end
  end

  def resolve(resolved:, schema:)
    adapter_class.new(resolved: resolved, schema: schema)
      .default_sequence_name('widgets', 'id')
  end

  it "strips the connection's own schema prefix" do
    expect(resolve(resolved: 'wssu.widgets_id_seq', schema: 'wssu'))
      .to(eq('widgets_id_seq'))
  end

  it 'preserves a prefix from another schema (persistent schemas, pinned public. qualification)' do
    expect(resolve(resolved: 'extensions.counters_id_seq', schema: 'wssu'))
      .to(eq('extensions.counters_id_seq'))
  end

  it 'does not mangle a schema whose name merely starts with the current schema' do
    expect(resolve(resolved: 'wssu_archive.widgets_id_seq', schema: 'wssu'))
      .to(eq('wssu_archive.widgets_id_seq'))
  end

  it 'passes through an already-unqualified name' do
    expect(resolve(resolved: 'widgets_id_seq', schema: 'wssu'))
      .to(eq('widgets_id_seq'))
  end

  it 'passes through nil (table has no serial sequence)' do
    expect(resolve(resolved: nil, schema: 'wssu')).to(be_nil)
  end
end
