# frozen_string_literal: true

module Apartment
  module DatabaseConfigurations
    class HashConfig < ActiveRecord::DatabaseConfigurations::HashConfig
      attr_reader :tenant

      def initialize(env_name, name, configuration_hash, tenant = nil)
        super(env_name, name, configuration_hash)
        @tenant = tenant
      end

      if ActiveRecord.version < Gem::Version.new('7.2.0')
        def inspect
          "#<#{self.class.name} env_name=#{@env_name} name=#{@name} tenant=#{tenant}>"
        end
      else
        def inspect
          "#<#{self.class.name} env_name=#{@env_name} name=#{@name} adapter_class=#{adapter_class} tenant=#{tenant}>"
        end
      end
    end
  end
end
