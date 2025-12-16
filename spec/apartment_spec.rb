# frozen_string_literal: true

require 'spec_helper'

describe Apartment do
  before { described_class.reset }

  it 'is valid' do
    expect(described_class).to(be_a(Module))
  end

  it 'is a valid app' do
    expect(Rails.application).to(be_a(Dummy::Application))
  end

  describe 'configuration' do
    describe '.parallel_strategy' do
      it 'defaults to :auto' do
        expect(described_class.parallel_strategy).to(eq(:auto))
      end

      it 'can be set to :threads' do
        described_class.parallel_strategy = :threads
        expect(described_class.parallel_strategy).to(eq(:threads))
      end

      it 'can be set to :processes' do
        described_class.parallel_strategy = :processes
        expect(described_class.parallel_strategy).to(eq(:processes))
      end
    end

    describe '.manage_advisory_locks' do
      it 'defaults to true' do
        expect(described_class.manage_advisory_locks).to(be(true))
      end

      it 'can be set to false' do
        described_class.manage_advisory_locks = false
        expect(described_class.manage_advisory_locks).to(be(false))
      end
    end

    describe '.consistent_rollback' do
      it 'defaults to false' do
        expect(described_class.consistent_rollback).to(be(false))
      end

      it 'can be set to true' do
        described_class.consistent_rollback = true
        expect(described_class.consistent_rollback).to(be(true))
      end
    end

    describe '.auto_dump_schema' do
      it 'defaults to true' do
        expect(described_class.auto_dump_schema).to(be(true))
      end

      it 'can be set to false' do
        described_class.auto_dump_schema = false
        expect(described_class.auto_dump_schema).to(be(false))
      end
    end

    describe '.auto_dump_schema_cache' do
      it 'defaults to false' do
        expect(described_class.auto_dump_schema_cache).to(be(false))
      end

      it 'can be set to true' do
        described_class.auto_dump_schema_cache = true
        expect(described_class.auto_dump_schema_cache).to(be(true))
      end
    end

    describe '.schema_dump_connection' do
      it 'defaults to nil' do
        expect(described_class.schema_dump_connection).to(be_nil)
      end

      it 'can be set to a connection name' do
        described_class.schema_dump_connection = 'primary'
        expect(described_class.schema_dump_connection).to(eq('primary'))
      end
    end

    describe '.parallel_migration_threads' do
      it 'defaults to 0' do
        expect(described_class.parallel_migration_threads).to(eq(0))
      end

      it 'can be set to a positive number' do
        described_class.parallel_migration_threads = 4
        expect(described_class.parallel_migration_threads).to(eq(4))
      end
    end

    describe '.reset' do
      it 'resets all configuration options to defaults' do
        described_class.parallel_strategy = :threads
        described_class.manage_advisory_locks = false
        described_class.consistent_rollback = true
        described_class.auto_dump_schema = false
        described_class.auto_dump_schema_cache = true
        described_class.schema_dump_connection = 'custom'
        described_class.parallel_migration_threads = 8

        described_class.reset

        expect(described_class.parallel_strategy).to(eq(:auto))
        expect(described_class.manage_advisory_locks).to(be(true))
        expect(described_class.consistent_rollback).to(be(false))
        expect(described_class.auto_dump_schema).to(be(true))
        expect(described_class.auto_dump_schema_cache).to(be(false))
        expect(described_class.schema_dump_connection).to(be_nil)
        expect(described_class.parallel_migration_threads).to(eq(0))
      end
    end
  end
end
