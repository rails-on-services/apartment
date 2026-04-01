# frozen_string_literal: true

require 'spec_helper'
require_relative '../../lib/apartment/tenant_name_validator'

RSpec.describe(Apartment::TenantNameValidator) do
  describe '.validate! common rules' do
    it 'rejects nil' do
      expect { described_class.validate!(nil, strategy: :schema) }
        .to(raise_error(Apartment::ConfigurationError, /must be a String/))
    end

    it 'rejects empty string' do
      expect { described_class.validate!('', strategy: :schema) }
        .to(raise_error(Apartment::ConfigurationError, /cannot be empty/))
    end

    it 'rejects NUL bytes' do
      expect { described_class.validate!("foo\x00bar", strategy: :schema) }
        .to(raise_error(Apartment::ConfigurationError, /NUL byte/))
    end

    it 'rejects whitespace' do
      expect { described_class.validate!('foo bar', strategy: :schema) }
        .to(raise_error(Apartment::ConfigurationError, /whitespace/))
    end

    it 'rejects tabs' do
      expect { described_class.validate!("foo\tbar", strategy: :schema) }
        .to(raise_error(Apartment::ConfigurationError, /whitespace/))
    end

    it 'rejects names containing colons' do
      expect do
        described_class.validate!('tenant:name', strategy: :schema)
      end.to(raise_error(Apartment::ConfigurationError, /colon/))
    end

    it 'rejects names longer than 255 characters' do
      expect { described_class.validate!('a' * 256, strategy: :database_name, adapter_name: 'sqlite3') }
        .to(raise_error(Apartment::ConfigurationError, /too long.*256.*max 255/))
    end

    it 'accepts valid names' do
      expect { described_class.validate!('acme', strategy: :schema) }.not_to(raise_error)
    end
  end

  describe 'PostgreSQL identifier rules' do
    it 'rejects names longer than 63 characters' do
      expect { described_class.validate!('a' * 64, strategy: :schema) }
        .to(raise_error(Apartment::ConfigurationError, /too long.*64.*max 63/))
    end

    it 'rejects names starting with pg_' do
      expect { described_class.validate!('pg_custom', strategy: :schema) }
        .to(raise_error(Apartment::ConfigurationError, /reserved prefix/))
    end

    it 'rejects names starting with a digit' do
      expect { described_class.validate!('123abc', strategy: :schema) }
        .to(raise_error(Apartment::ConfigurationError, /Invalid PostgreSQL identifier/))
    end

    it 'rejects names with special characters' do
      expect { described_class.validate!('foo@bar', strategy: :schema) }
        .to(raise_error(Apartment::ConfigurationError, /Invalid PostgreSQL identifier/))
    end

    it 'allows hyphens (quoted by adapters)' do
      expect { described_class.validate!('my-tenant', strategy: :schema) }.not_to(raise_error)
    end

    it 'allows underscores' do
      expect { described_class.validate!('my_tenant', strategy: :schema) }.not_to(raise_error)
    end

    it 'allows names starting with underscore' do
      expect { described_class.validate!('_private', strategy: :schema) }.not_to(raise_error)
    end

    it 'accepts exactly 63 characters' do
      expect { described_class.validate!('a' * 63, strategy: :schema) }.not_to(raise_error)
    end
  end

  describe 'MySQL database name rules' do
    let(:opts) { { strategy: :database_name, adapter_name: 'mysql2' } }

    it 'rejects names longer than 64 characters' do
      expect { described_class.validate!('a' * 65, **opts) }
        .to(raise_error(Apartment::ConfigurationError, /too long.*65.*max 64/))
    end

    it 'rejects names starting with a digit' do
      expect { described_class.validate!('123abc', **opts) }
        .to(raise_error(Apartment::ConfigurationError, /cannot start with a digit/))
    end

    it 'rejects names ending with a period' do
      expect { described_class.validate!('foo.', **opts) }
        .to(raise_error(Apartment::ConfigurationError, /cannot end with a period/))
    end

    it 'rejects names with invalid characters' do
      expect { described_class.validate!('foo@bar', **opts) }
        .to(raise_error(Apartment::ConfigurationError, /Invalid MySQL/))
    end

    it 'allows hyphens and dollar signs' do
      expect { described_class.validate!('my-tenant$1', **opts) }.not_to(raise_error)
    end

    it 'applies to trilogy adapter' do
      expect { described_class.validate!('foo@bar', strategy: :database_name, adapter_name: 'trilogy') }
        .to(raise_error(Apartment::ConfigurationError, /Invalid MySQL/))
    end

    it 'accepts exactly 64 characters' do
      expect { described_class.validate!('a' * 64, **opts) }.not_to(raise_error)
    end
  end

  describe 'SQLite path rules' do
    let(:opts) { { strategy: :database_name, adapter_name: 'sqlite3' } }

    it 'rejects path traversal' do
      expect { described_class.validate!('../escape', **opts) }
        .to(raise_error(Apartment::ConfigurationError, /path traversal/))
    end

    it 'rejects forward slash path separators' do
      expect { described_class.validate!('dir/name', **opts) }
        .to(raise_error(Apartment::ConfigurationError, /path separators/))
    end

    it 'rejects backslash path separators' do
      expect { described_class.validate!('dir\\name', **opts) }
        .to(raise_error(Apartment::ConfigurationError, /path separators/))
    end

    it 'allows normal names' do
      expect { described_class.validate!('my_tenant', **opts) }.not_to(raise_error)
    end

    it 'allows hyphens and dots in names' do
      expect { described_class.validate!('my-tenant.v2', **opts) }.not_to(raise_error)
    end
  end

  describe 'unknown strategy' do
    it 'applies only common validation for :shard strategy' do
      expect { described_class.validate!('acme', strategy: :shard) }.not_to(raise_error)
    end

    it 'applies only common validation for :database_config strategy' do
      expect { described_class.validate!('acme', strategy: :database_config) }.not_to(raise_error)
    end
  end
end
