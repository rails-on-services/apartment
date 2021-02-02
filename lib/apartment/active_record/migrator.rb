# frozen_string_literal: true

# Monkey patch ActiveRecord::Migrator to allow parallel ros-apartment migrations
# see -> https://github.com/rails/rails/pull/40251
# TODO -> Remove whenever ros-apartment or rails implements a fix for threaded migrations

module ActiveRecord
  class Migrator < ActiveRecord # :nodoc:
    class << self
      def generate_migrator_advisory_lock_id
        hash_input = ActiveRecord::Base.connection.current_database
        hash_input += ActiveRecord::Base.connection.current_schema
        db_name_hash = Zlib.crc32(hash_input)
        MIGRATOR_SALT * db_name_hash
      end
    end
  end
end
