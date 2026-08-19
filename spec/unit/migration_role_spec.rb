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

  # Reality, verified against Rails 8.1: connected_to(role:) resolves no pool. It
  # pushes onto connected_to_stack and yields, so an unregistered role surfaces only
  # when the BLOCK asks for a connection. Every example below therefore yields, and
  # the earlier version of this spec — which stubbed connected_to to raise without
  # yielding — could not fail, because Rails never does that.
  #
  # Every example raises ActiveRecord::ConnectionNotEstablished and never the
  # ConnectionNotDefined subclass, which does not exist before Rails 8.0: an example
  # naming it would pass on 8.1 and die of NameError on the Rails floor. The verdict
  # under test never comes from the error class anyway — it comes from the probe, which
  # is stubbed at ActiveRecord's own seam rather than simulated. Nil is what a missing
  # role looks like there, a pool is what a present one looks like, and the same pair
  # of examples therefore means the same thing on every supported Rails.
  def stub_role_pool(pool)
    handler = instance_double(ActiveRecord::ConnectionAdapters::ConnectionHandler)
    allow(ActiveRecord::Base).to(receive(:connection_handler).and_return(handler))
    allow(handler).to(receive(:retrieve_connection_pool).and_return(pool))
  end

  # A wrap whose block never touches the database is silent by design, even with an
  # unresolvable role: it did not need the role to exist. Do not "fix" this by
  # probing before the yield — that invents a failure, and it breaks a role
  # registered lazily on a model load that has not happened yet.
  it 'stays silent when the block never asks for a connection' do
    configure(:nope)
    allow(ActiveRecord::Base).to(receive(:connected_to).and_yield)

    expect(described_class.wrap { :ran }).to(eq(:ran))
  end

  # The check is here rather than at activate! because activate! runs in
  # after_initialize, which fires after the eager-load initializer — so under lazy
  # loading (development, most test setups) no model has run connects_to yet and a
  # boot-time check would fail on every boot.
  it 'translates an unresolvable role into a ConfigurationError naming the key', :aggregate_failures do
    configure(:nope)
    allow(ActiveRecord::Base).to(receive(:connected_to).and_yield)
    stub_role_pool(nil)

    raised = nil
    begin
      described_class.wrap { raise(ActiveRecord::ConnectionNotEstablished, 'No connection pool for role :nope') }
    rescue StandardError => e
      raised = e
    end

    expect(raised).to(be_a(Apartment::ConfigurationError))
    expect(raised.message).to(match(/ddl_role.*:nope/))
    expect(raised.cause).to(be_a(ActiveRecord::ConnectionNotEstablished))
  end

  # Same error, opposite verdict, and the only difference between this example and the
  # one above is what the probe answers. That is the point: our role resolves, so the
  # failure is about some other connection the caller asked for, and blaming ddl_role
  # would send the reader to the wrong config key. Nothing here depends on the error
  # class, which is what makes the pair meaningful on Rails 7.2 as well as 8.1.
  it 'does not blame ddl_role when our role resolves and the block still fails', :aggregate_failures do
    configure(:db_manager)
    allow(ActiveRecord::Base).to(receive(:connected_to).and_yield)
    stub_role_pool(instance_double(ActiveRecord::ConnectionAdapters::ConnectionPool))

    raised = nil
    begin
      described_class.wrap { raise(ActiveRecord::ConnectionNotEstablished, 'server closed the connection') }
    rescue StandardError => e
      raised = e
    end

    expect(raised).to(be_a(ActiveRecord::ConnectionNotEstablished))
    expect(raised.message).to(eq('server closed the connection'))
  end

  # The classifier must not mask the original error when it cannot answer.
  it 'reports the role as registered when the probe itself fails' do
    configure(:nope)
    allow(ActiveRecord::Base).to(receive(:connected_to).and_yield)
    allow(ActiveRecord::Base).to(receive(:connection_handler).and_raise(RuntimeError, 'handler gone'))

    expect { described_class.wrap { raise(ActiveRecord::ConnectionNotEstablished, 'no pool') } }
      .to(raise_error(ActiveRecord::ConnectionNotEstablished, 'no pool'))
  end

  it 'does not swallow an error raised by the block itself' do
    configure(:db_manager)
    allow(ActiveRecord::Base).to(receive(:connected_to).and_yield)

    expect { described_class.wrap { raise(ArgumentError, 'from the block') } }
      .to(raise_error(ArgumentError, 'from the block'))
  end
end
