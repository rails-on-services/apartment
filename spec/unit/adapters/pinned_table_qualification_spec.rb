# frozen_string_literal: true

require 'spec_helper'
require 'active_record'
require_relative '../../../lib/apartment/adapters/postgresql_schema_adapter'
require_relative '../../../lib/apartment/adapters/mysql2_adapter'

# End-to-end behaviour of pinned table-name qualification, asserted on the
# resulting table_name rather than on the mutators used to get there.
#
# The per-adapter specs mock table_name_prefix=/reset_table_name/table_name=,
# which cannot see whether the mutation actually took effect. Every regression
# guarded here was invisible to that style: Rails silently ignores
# table_name_prefix for whole categories of model (see compute_table_name).
RSpec.describe('pinned table name qualification') do
  # Each example builds real AR classes so Rails' own compute_table_name /
  # reset_table_name run for real. Named via stub_const so model_name works.
  def model(name, parent = ActiveRecord::Base, &body)
    klass = Class.new(parent) { include(Apartment::Model) }
    stub_const(name, klass)
    klass.class_eval(&body) if body
    klass
  end

  shared_examples 'a qualifying adapter' do |qualifier|
    it 'qualifies a plain convention-named model' do
      klass = model('QualPlainWidget')

      adapter.qualify_pinned_table_name(klass)

      expect(klass.table_name).to(eq("#{qualifier}.qual_plain_widgets"))
    end

    it 'qualifies a model with an explicit table_name' do
      klass = model('QualCustomJob') { self.table_name = 'custom_jobs' }

      adapter.qualify_pinned_table_name(klass)

      expect(klass.table_name).to(eq("#{qualifier}.custom_jobs"))
    end

    it 'replaces an existing qualifier rather than stacking one' do
      klass = model('QualRequalified') { self.table_name = 'old_schema.jobs' }

      adapter.qualify_pinned_table_name(klass)

      expect(klass.table_name).to(eq("#{qualifier}.jobs"))
    end

    # Regression: a subclass is not its own base_class, so Rails'
    # compute_table_name returns base_class.table_name verbatim and never
    # consults full_table_name_prefix. The convention path set the prefix and
    # the model kept resolving through search_path to the *tenant's* table.
    it 'qualifies a subclass whose explicit table_name matches its base class' do
      model('QualBaseVersion') { self.table_name = 'versions' }
      klass = model('QualPublicVersion', QualBaseVersion) { self.table_name = 'versions' }

      adapter.qualify_pinned_table_name(klass)

      expect(klass.base_class?).to(be(false))
      expect(klass.table_name).to(eq("#{qualifier}.versions"))
    end

    # Regression: full_table_name_prefix prefers the first module parent that
    # responds to table_name_prefix, so a prefix set on the class itself is
    # ignored outright for engine-namespaced models.
    it 'qualifies a model whose module parent defines table_name_prefix' do
      mod = Module.new { def self.table_name_prefix = 'billing_' }
      stub_const('QualBilling', mod)
      klass = model('QualBilling::Invoice')

      adapter.qualify_pinned_table_name(klass)

      expect(klass.table_name).to(eq("#{qualifier}.billing_invoices"))
    end

    # Regression: overwriting table_name_prefix dropped the app's own prefix,
    # pointing the model at a table that does not exist (or, worse, a
    # different one) instead of merely leaving it unqualified.
    it "preserves the model's own table_name_prefix while qualifying" do
      klass = model('QualLedger') { self.table_name_prefix = 'myapp_' }

      adapter.qualify_pinned_table_name(klass)

      expect(klass.table_name).to(eq("#{qualifier}.myapp_qual_ledgers"))
    end

    it 'marks the model processed' do
      klass = model('QualProcessed')

      adapter.qualify_pinned_table_name(klass)

      expect(klass.apartment_pinned_processed?).to(be(true))
    end

    # An abstract class has no table of its own (table_name is nil), so there
    # is nothing to qualify. Pinning one is a documented pattern — an abstract
    # `connects_to` base is pinned to stop Apartment building tenant pools for
    # it — so this must stay a no-op rather than raising at boot.
    it 'skips an abstract class instead of raising' do
      klass = model('QualAbstractBase') { self.abstract_class = true }

      expect { adapter.qualify_pinned_table_name(klass) }.not_to(raise_error)
      expect(klass.table_name).to(be_nil)
      expect(klass.apartment_pinned_processed?).to(be(true))
    end

    it 'leaves a concrete child of a pinned abstract base qualifiable' do
      parent = model('QualAbstractParent') { self.abstract_class = true }
      adapter.qualify_pinned_table_name(parent)
      child = model('QualConcreteChild', parent)

      adapter.qualify_pinned_table_name(child)

      expect(child.table_name).to(eq("#{qualifier}.qual_concrete_children"))
    end
  end

  shared_examples 'a restoring adapter' do
    it 'restores an explicit table_name verbatim' do
      klass = model('RestoreCustomJob') { self.table_name = 'custom_jobs' }

      adapter.qualify_pinned_table_name(klass)
      klass.apartment_restore!

      expect(klass.table_name).to(eq('custom_jobs'))
    end

    it 'restores a convention-named model to its recomputed name' do
      klass = model('RestoreWidget')

      adapter.qualify_pinned_table_name(klass)
      klass.apartment_restore!

      expect(klass.table_name).to(eq('restore_widgets'))
    end

    it "restores a model's own table_name_prefix" do
      klass = model('RestoreLedger') { self.table_name_prefix = 'myapp_' }

      adapter.qualify_pinned_table_name(klass)
      klass.apartment_restore!

      expect(klass.table_name).to(eq('myapp_restore_ledgers'))
      expect(klass.table_name_prefix).to(eq('myapp_'))
    end

    it 'restores a subclass to its base class table' do
      model('RestoreBaseVersion') { self.table_name = 'versions' }
      klass = model('RestorePublicVersion', RestoreBaseVersion) { self.table_name = 'versions' }

      adapter.qualify_pinned_table_name(klass)
      klass.apartment_restore!

      expect(klass.table_name).to(eq('versions'))
    end

    it 'restores an abstract class as a no-op' do
      klass = model('RestoreAbstractBase') { self.abstract_class = true }

      adapter.qualify_pinned_table_name(klass)
      expect { klass.apartment_restore! }.not_to(raise_error)

      expect(klass.table_name).to(be_nil)
      expect(klass.apartment_pinned_processed?).to(be(false))
    end

    it 'leaves the model requalifiable after a restore' do
      klass = model('RestoreCycleWidget')

      2.times do
        adapter.qualify_pinned_table_name(klass)
        klass.apartment_restore!
      end
      adapter.qualify_pinned_table_name(klass)

      expect(klass.table_name).to(eq("#{expected_qualifier}.restore_cycle_widgets"))
    end
  end

  context 'with the PostgreSQL schema adapter' do
    let(:adapter) do
      Apartment::Adapters::PostgresqlSchemaAdapter.new({ adapter: 'postgresql', database: 'myapp' })
    end
    let(:expected_qualifier) { 'public' }

    before do
      Apartment.configure do |c|
        c.tenant_strategy = :schema
        c.tenants_provider = -> { %w[t1 t2] }
        c.default_tenant = 'public'
        c.schema_load_strategy = nil
      end
    end

    it_behaves_like 'a qualifying adapter', 'public'
    it_behaves_like 'a restoring adapter'
  end

  context 'with the MySQL adapter' do
    let(:adapter) do
      Apartment::Adapters::Mysql2Adapter.new({ adapter: 'mysql2', database: 'myapp' })
    end
    let(:expected_qualifier) { 'myapp' }

    before do
      Apartment.configure do |c|
        c.tenant_strategy = :database_name
        c.tenants_provider = -> { %w[t1 t2] }
        c.default_tenant = 'myapp'
        c.schema_load_strategy = nil
      end
    end

    it_behaves_like 'a qualifying adapter', 'myapp'
    it_behaves_like 'a restoring adapter'
  end
end
