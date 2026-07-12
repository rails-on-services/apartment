# frozen_string_literal: true

require 'spec_helper'

# Pure-logic spec: the module only needs `super` (the Rails-resolved, possibly
# schema-qualified sequence name) and the table name, so a fake adapter class
# exercises every branch without a database.
#
# Requires real ActiveRecord + pg for the PostgreSQL::Utils name splitter.
# Skips gracefully otherwise (run via any postgresql appraisal).
PG_UTILS_AVAILABLE = begin
  require('active_record')
  require('active_record/connection_adapters/postgresql_adapter')
  true
rescue LoadError => e
  warn "[postgresql_sequence_name_spec] Skipping: #{e.message}"
  false
end

RSpec.describe(Apartment::Patches::PostgresqlSequenceName) do
  before { skip('requires the pg gem (run via a postgresql appraisal)') unless PG_UTILS_AVAILABLE }

  let(:adapter_class) do
    Class.new do
      prepend(Apartment::Patches::PostgresqlSequenceName)

      def initialize(resolved:)
        @resolved = resolved
      end

      def default_sequence_name(_table, _column)
        @resolved
      end
    end
  end

  def resolve(resolved:, table: 'widgets')
    adapter_class.new(resolved: resolved).default_sequence_name(table, 'id')
  end

  describe 'routed (unqualified) tables' do
    it "strips the connection's own schema prefix" do
      expect(resolve(resolved: 'wssu.widgets_id_seq')).to(eq('widgets_id_seq'))
    end

    # The search_path-fallback case: the tenant schema is missing the table, so
    # PG resolves the sequence in whichever schema HAS it. Preserving that
    # prefix would memoize the fallback schema for every tenant, process-wide.
    it 'strips a FOREIGN schema prefix too, so the memo never pins a fallback schema' do
      expect(resolve(resolved: 'public.widgets_id_seq')).to(eq('widgets_id_seq'))
    end

    it 'handles a schema name that required quoting (AR hands us the unquoted form)' do
      expect(resolve(resolved: 'Weird-Tenant.widgets_id_seq')).to(eq('widgets_id_seq'))
    end

    it 'passes through an already-unqualified name' do
      expect(resolve(resolved: 'widgets_id_seq')).to(eq('widgets_id_seq'))
    end

    it 'passes through nil (table has no serial sequence)' do
      expect(resolve(resolved: nil)).to(be_nil)
    end
  end

  # A qualified table name means a pinned model (Apartment qualifies those to
  # the default tenant). Its sequence must stay qualified, whichever connection
  # resolves it -- including the default pool at boot, where the connection's own
  # schema IS the prefix. Which connection is current no longer enters the logic
  # here, so this is one case at the unit level; the integration spec covers both
  # resolution orders against a real search_path.
  describe 'pinned (schema-qualified) tables' do
    it 'preserves the qualified sequence' do
      expect(resolve(resolved: 'public.settings_id_seq', table: 'public.settings'))
        .to(eq('public.settings_id_seq'))
    end
  end
end
