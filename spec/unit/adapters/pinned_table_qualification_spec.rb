# frozen_string_literal: true

require 'spec_helper'
require 'active_record'
require_relative '../../../lib/apartment/adapters/postgresql_schema_adapter'
require_relative '../../../lib/apartment/adapters/mysql2_adapter'

# End-to-end behaviour of pinned table-name qualification, asserted on the
# resulting table_name rather than on the mutators used to get there.
#
# Asserting on the mutators instead — mocking table_name_prefix= /
# reset_table_name / table_name= — cannot see whether the mutation took effect,
# and Rails silently ignores table_name_prefix for whole categories of model
# (see compute_table_name), so the distinction is not academic.
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

    # A subclass is not its own base_class, so Rails' compute_table_name
    # returns base_class.table_name verbatim and never consults
    # full_table_name_prefix. Prefix-based qualification therefore cannot reach
    # it, and it resolves through search_path to the *tenant's* table.
    it 'qualifies a subclass whose explicit table_name matches its base class' do
      model('QualBaseVersion') { self.table_name = 'versions' }
      klass = model('QualPublicVersion', QualBaseVersion) { self.table_name = 'versions' }

      adapter.qualify_pinned_table_name(klass)

      expect(klass.base_class?).to(be(false))
      expect(klass.table_name).to(eq("#{qualifier}.versions"))
    end

    # full_table_name_prefix prefers the first module parent that responds to
    # table_name_prefix, so a prefix set on the class itself is ignored
    # outright for engine-namespaced models.
    it 'qualifies a model whose module parent defines table_name_prefix' do
      mod = Module.new { def self.table_name_prefix = 'billing_' }
      stub_const('QualBilling', mod)
      klass = model('QualBilling::Invoice')

      adapter.qualify_pinned_table_name(klass)

      expect(klass.table_name).to(eq("#{qualifier}.billing_invoices"))
    end

    # Overwriting table_name_prefix would drop the app's own prefix, pointing
    # the model at a table that does not exist (or, worse, a different one)
    # rather than merely leaving it unqualified.
    it "preserves the model's own table_name_prefix while qualifying" do
      klass = model('QualLedger') { self.table_name_prefix = 'myapp_' }

      adapter.qualify_pinned_table_name(klass)

      expect(klass.table_name).to(eq("#{qualifier}.myapp_qual_ledgers"))
    end

    # Rails memoizes @table_name per class on first read and never invalidates
    # a descendant's copy when an ancestor's name or prefix changes. Anything
    # that touches a descendant's table_name before Tenant.init — an
    # initializer, a gem, a route constraint, a descendants sweep — freezes the
    # UNqualified name, and the "pinned" model then reads the tenant's table
    # forever. Qualification has to resync them.
    it 'requalifies a descendant that memoized its name before the base was qualified' do
      parent = model('MemoBase') { self.abstract_class = true }
      child = Class.new(parent)
      stub_const('MemoChild', child)
      child.table_name # early read freezes the unqualified name

      adapter.qualify_pinned_table_name(parent)

      expect(child.table_name).to(eq("#{qualifier}.memo_children"))
    end

    it 'requalifies an STI child that memoized the parent table early' do
      parent = model('StiMemoParent') { self.table_name = 'sti_memo_parents' }
      child = Class.new(parent)
      stub_const('StiMemoChild', child)
      child.table_name

      adapter.qualify_pinned_table_name(parent)

      expect(child.table_name).to(eq("#{qualifier}.sti_memo_parents"))
    end

    # Three levels, with an abstract intermediate that carries a table. Rails'
    # reset_table_name prefers superclass.table_name here, while
    # compute_table_name treats the grandchild as its own base_class and builds
    # from its own model_name — so the two disagree, and keying the resync on
    # compute_table_name misreads the grandchild's INHERITED name as an
    # explicit declaration and skips it, leaving it on the tenant's table.
    it 'requalifies a grandchild under an abstract intermediate' do
      base = model('ChainBase') { self.table_name = 'chain_foos' }
      mid = Class.new(base) { self.abstract_class = true }
      stub_const('ChainMid', mid)
      grandchild = Class.new(mid)
      stub_const('ChainKid', grandchild)
      mid.table_name
      grandchild.table_name # both memoize the unqualified inherited name

      adapter.qualify_pinned_table_name(base)

      expect(grandchild.table_name).to(eq("#{qualifier}.chain_foos"))
    end

    it 'leaves a descendant that declares its own table alone' do
      parent = model('OwnTableBase') { self.abstract_class = true }
      child = Class.new(parent) { self.table_name = 'declared_table' }
      stub_const('OwnTableChild', child)

      adapter.qualify_pinned_table_name(parent)

      expect(child.table_name).to(eq('declared_table'))
    end

    # Descendants WARN rather than raise: detection walks `descendants`, which
    # is complete under eager loading and partial under Zeitwerk, so raising
    # would fail production boots for a condition dev never reports while still
    # missing descendants that load later. The registered model itself raises —
    # that check is complete (see the qualifier and self specs below).
    #
    # This shape is the live example: `full_table_name_prefix` prefers the
    # module parent's prefix, so an abstract base's broadcast never reaches an
    # engine-namespaced descendant.
    it 'warns when a resynced descendant is left unqualified' do
      parent = model('VerifyBase') { self.abstract_class = true }
      mod = Module.new { def self.table_name_prefix = 'engine_' }
      stub_const('VerifyEngine', mod)
      child = Class.new(parent)
      stub_const('VerifyEngine::Thing', child)
      child.table_name

      expect { adapter.qualify_pinned_table_name(parent) }
        .to(output(/VerifyEngine::Thing.*engine_things/m).to_stderr)
    end

    # The natural shape: nothing read the descendant first, so it holds no memo
    # and is not part of the resync set. Verifying only resynced descendants
    # would miss it entirely — a descendant with no memo inherits its name
    # lazily and can be just as wrong.
    it 'warns for an unqualified descendant that was never read' do
      parent = model('VerifyLazyBase') { self.abstract_class = true }
      mod = Module.new { def self.table_name_prefix = 'lazy_engine_' }
      stub_const('VerifyLazyEngine', mod)
      stub_const('VerifyLazyEngine::Thing', Class.new(parent))

      expect { adapter.qualify_pinned_table_name(parent) }
        .to(output(/lazy_engine_things/).to_stderr)
    end

    # The remedy the error message prescribes must actually work. Registry
    # order is always parent-first (defining the child loads the parent), so
    # verifying the base's descendants would raise on a descendant that is
    # itself registered and about to be qualified on the next iteration —
    # failing the boot of an app that did exactly the right thing.
    it 'does not raise for a descendant that is itself pinned and not yet processed' do
      parent = model('RemedyBase') { self.abstract_class = true }
      parent.pin_tenant
      mod = Module.new { def self.table_name_prefix = 'remedy_engine_' }
      stub_const('RemedyEngine', mod)
      child = Class.new(parent) { include(Apartment::Model) }
      stub_const('RemedyEngine::Thing', child)
      child.pin_tenant

      expect { adapter.qualify_pinned_table_name(parent) }.not_to(output.to_stderr)
    end

    it 'still warns once that descendant has been processed and is unqualified' do
      parent = model('RemedyDoneBase') { self.abstract_class = true }
      parent.pin_tenant
      mod = Module.new { def self.table_name_prefix = 'done_engine_' }
      stub_const('DoneEngine', mod)
      child = Class.new(parent) { include(Apartment::Model) }
      stub_const('DoneEngine::Thing', child)
      child.pin_tenant
      child.apartment_mark_processed! # pretend its turn came and left it unqualified

      expect { adapter.qualify_pinned_table_name(parent) }
        .to(output(/done_engine_things/).to_stderr)
    end

    # A nil qualifier produces a bare ".table", which start_with?('.') would
    # happily accept — the check proving nothing in exactly the case it exists
    # for. On MySQL this is a connection config with no 'database' key.
    it 'raises when the qualifier itself is empty' do
      klass = model('EmptyQualifier')
      allow(adapter).to(receive(:pinned_table_qualifier).and_return(nil))

      expect { adapter.qualify_pinned_table_name(klass) }.to(
        raise_error(Apartment::ConfigurationError, /pinned_table_qualifier is nil/)
      )
    end

    it 'does not raise for a descendant that declares its own table' do
      parent = model('VerifyDeclaredBase') { self.abstract_class = true }
      child = Class.new(parent) { self.table_name = 'declared_elsewhere' }
      stub_const('VerifyDeclaredChild', child)

      expect { adapter.qualify_pinned_table_name(parent) }.not_to(raise_error)
    end

    it 'raises when the model itself is left unqualified' do
      klass = model('VerifyStubborn')
      # Simulate qualification failing to take effect — the shape every past
      # bug had, and what a future Rails change to the naming internals would
      # look like.
      allow(klass).to(receive(:table_name).and_return('verify_stubborns'))

      expect { adapter.qualify_pinned_table_name(klass) }.to(
        raise_error(Apartment::ConfigurationError, /verify_stubborns/)
      )
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

    # `pin_tenant` early-returns once any superclass is pinned, so concrete
    # descendants of a pinned abstract base are never registered and never
    # reach qualification on their own. The abstract base's qualifier has to
    # reach them, which is what table_name_prefix (a class_attribute) is for.
    # Without this the descendants silently read the *tenant's* table.
    it 'qualifies concrete descendants of a pinned abstract base' do
      parent = model('QualGlobalRecord') { self.abstract_class = true }
      child = Class.new(parent)
      stub_const('QualGlobalSetting', child)

      adapter.qualify_pinned_table_name(parent)

      expect(child.table_name).to(eq("#{qualifier}.qual_global_settings"))
    end

    it "preserves an abstract base's own table_name_prefix for its descendants" do
      parent = model('QualPrefixedBase') do
        self.abstract_class = true
        self.table_name_prefix = 'myapp_'
      end
      child = Class.new(parent)
      stub_const('QualPrefixedChild', child)

      adapter.qualify_pinned_table_name(parent)

      expect(child.table_name).to(eq("#{qualifier}.myapp_qual_prefixed_children"))
    end

    # A subclass that shares an already-pinned base's table resolves through
    # base_class.table_name, which the base's own qualification already covers.
    # Assigning here would freeze a copy of the base's name onto the child and
    # desynchronise the two on teardown.
    it 'leaves an STI child of a pinned base alone' do
      parent = model('QualStiParent') { self.table_name = 'sti_parents' }
      parent.pin_tenant
      adapter.qualify_pinned_table_name(parent)
      child = Class.new(parent) { include(Apartment::Model) }
      stub_const('QualStiChild', child)

      adapter.qualify_pinned_table_name(child)

      expect(child.instance_variable_defined?(:@table_name)).to(be(false))
      expect(child.table_name).to(eq("#{qualifier}.sti_parents"))
    end

    # The transitional shape: a subclass moving off the pinned parent's table.
    # It has a table of its own, so it must be qualified on its own merits.
    it 'qualifies a subclass of a pinned base that declares its own table' do
      parent = model('QualMigParent') { self.table_name = 'mig_parents' }
      parent.pin_tenant
      adapter.qualify_pinned_table_name(parent)
      child = model('QualMigChild', parent) { self.table_name = 'mig_children' }

      adapter.qualify_pinned_table_name(child)

      expect(child.table_name).to(eq("#{qualifier}.mig_children"))
    end

    it 'leaves a separately registered concrete child idempotent' do
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

    it "restores an abstract base's prefix, unqualifying its descendants" do
      parent = model('RestoreGlobalRecord') do
        self.abstract_class = true
        self.table_name_prefix = 'myapp_'
      end
      child = Class.new(parent)
      stub_const('RestoreGlobalSetting', child)

      adapter.qualify_pinned_table_name(parent)
      parent.apartment_restore!
      child.reset_table_name

      expect(parent.table_name_prefix).to(eq('myapp_'))
      expect(child.table_name).to(eq('myapp_restore_global_settings'))
      expect(parent.apartment_pinned_processed?).to(be(false))
    end

    it 'unqualifies a descendant that memoized the qualified name' do
      parent = model('MemoRestoreBase') { self.abstract_class = true }
      child = Class.new(parent)
      stub_const('MemoRestoreChild', child)

      adapter.qualify_pinned_table_name(parent)
      child.table_name # freeze the qualified name on the descendant
      parent.apartment_restore!

      expect(child.table_name).to(eq('memo_restore_children'))
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
