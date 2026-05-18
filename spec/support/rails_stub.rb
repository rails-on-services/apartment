# frozen_string_literal: true

require 'active_support/string_inquirer'
require 'pathname'

# Minimal Rails stub for specs that load ActiveRecord without booting the
# Rails framework (the dummy app in spec/dummy/ remains the path for specs
# that need a real Rails — see spec/integration/v4/request_lifecycle_spec.rb).
#
# `Rails.env` returns an `ActiveSupport::StringInquirer` so `.test?` and the
# string-comparison form (`Rails.env == 'test'`) both work. `Rails.root` is
# provided for adapter specs that resolve schema-file paths against it.
#
# Specs that need to simulate a different env override per-example via
# `allow(Rails).to(receive(:env).and_return(ActiveSupport::StringInquirer.new('...')))`.
#
# `unless defined?(Rails)` keeps the stub out of the way when a spec
# subsequently loads the dummy app — the real Rails framework re-opens the
# module and its own singleton methods replace these.
unless defined?(Rails)
  module Rails
    def self.env
      ActiveSupport::StringInquirer.new('test')
    end

    def self.root
      Pathname.new('/rails/app')
    end
  end
end
