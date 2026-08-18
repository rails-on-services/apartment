# frozen_string_literal: true

require 'spec_helper'

RSpec.describe(Apartment::Privileges::Context) do
  let(:connection) { instance_double(ActiveRecord::ConnectionAdapters::AbstractAdapter) }

  def build(phase: :before_schema_load)
    described_class.new(
      tenant: 'acme', container_name: 'acme_test', connection: connection,
      db_role: 'db_manager', phase: phase
    )
  end

  it 'exposes every field it was built with', :aggregate_failures do
    ctx = build

    expect(ctx.tenant).to(eq('acme'))
    expect(ctx.container_name).to(eq('acme_test'))
    expect(ctx.connection).to(be(connection))
    expect(ctx.db_role).to(eq('db_manager'))
    expect(ctx.phase).to(eq(:before_schema_load))
  end

  it 'answers the phase predicates', :aggregate_failures do
    expect(build(phase: :before_schema_load)).to(be_before_schema_load)
    expect(build(phase: :before_schema_load)).not_to(be_after_schema_load)
    expect(build(phase: :after_schema_load)).to(be_after_schema_load)
  end

  it 'quotes the container name through the connection' do
    allow(connection).to(receive(:quote_table_name).with('acme_test').and_return('"acme_test"'))

    expect(build.quoted_container).to(eq('"acme_test"'))
  end

  it 'is frozen, so a policy cannot mutate what a later phase sees' do
    expect(build).to(be_frozen)
  end

  # The compatibility promise in docs/designs/v4-rbac-contract.md: a policy that
  # reads attributes keeps working when a field is added. Data.define would have
  # broken this for anyone constructing or positionally destructuring a context.
  it 'accepts an unknown future field without breaking existing readers' do
    ctx = described_class.new(
      tenant: 'acme', container_name: 'acme_test', connection: connection,
      db_role: 'db_manager', phase: :before_schema_load, future_field: 'ignored'
    )

    expect(ctx.tenant).to(eq('acme'))
  end
end
