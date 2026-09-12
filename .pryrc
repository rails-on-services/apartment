# frozen_string_literal: true

# rubocop:disable-next Style/MixinUsage
extend Rails::ConsoleMethods if defined?(Rails) && Rails.env
