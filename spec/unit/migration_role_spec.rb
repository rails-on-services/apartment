# frozen_string_literal: true

require 'spec_helper'

RSpec.describe(Apartment::MigrationRole) do
  def configure(role)
    Apartment.configure do |c|
      c.tenant_strategy = :schema
      c.tenants_provider = -> { [] }
      c.default_tenant = 'public'
      c.ddl_role = role
    end
  end

  it 'yields without connected_to when no role is configured' do
    configure(nil)
    expect(ActiveRecord::Base).not_to(receive(:connected_to))

    expect(described_class.wrap { :ran }).to(eq(:ran))
  end

  it 'wraps in connected_to when a role is configured' do
    configure(:db_manager)
    expect(ActiveRecord::Base).to(receive(:connected_to).with(role: :db_manager).and_yield)

    described_class.wrap { :ran }
  end

  # The check is here rather than at activate! because activate! runs in
  # after_initialize, which fires after the eager-load initializer — so under lazy
  # loading (development, most test setups) no model has run connects_to yet and a
  # boot-time check would fail on every boot.
  it 'translates an unresolvable role into a ConfigurationError naming the key', :aggregate_failures do
    configure(:nope)
    allow(ActiveRecord::Base).to(receive(:connected_to)
      .and_raise(ActiveRecord::ConnectionNotDefined, 'No connection pool for role :nope'))

    raised = nil
    begin
      described_class.wrap { :never }
    rescue StandardError => e
      raised = e
    end

    expect(raised).to(be_a(Apartment::ConfigurationError))
    expect(raised.message).to(match(/ddl_role.*:nope/))
    expect(raised.cause).to(be_a(ActiveRecord::ConnectionNotDefined))
  end

  it 'does not swallow an error raised by the block itself' do
    configure(:db_manager)
    allow(ActiveRecord::Base).to(receive(:connected_to).and_yield)

    expect { described_class.wrap { raise(ArgumentError, 'from the block') } }
      .to(raise_error(ArgumentError, 'from the block'))
  end

  # The example that actually exercises the +entered+ guard. An ArgumentError from
  # the block never reaches the rescue, so it proves nothing about the guard; a
  # ConnectionNotEstablished raised by a query INSIDE the block hits the same rescue
  # as a role that could not be entered, and must still surface as itself. Without
  # the guard, a caller's own connection failure would be reported as "your ddl_role
  # is misconfigured".
  it 'does not blame ddl_role for a connection error the block itself raised', :aggregate_failures do
    configure(:db_manager)
    allow(ActiveRecord::Base).to(receive(:connected_to).and_yield)

    raised = nil
    begin
      described_class.wrap { raise(ActiveRecord::ConnectionNotEstablished, 'from a query in the block') }
    rescue StandardError => e
      raised = e
    end

    expect(raised).to(be_a(ActiveRecord::ConnectionNotEstablished))
    expect(raised.message).to(eq('from a query in the block'))
  end
end
