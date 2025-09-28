# frozen_string_literal: true

class CreatePublicTokens < ActiveRecord::Migration[Rails::VERSION::STRING.to_f]
  def change
    create_table(:public_tokens) do |t|
      t.string(:name, null: false)
      t.string(:token, null: false)
      t.references(:company, null: false, foreign_key: true)

      t.timestamps
    end
  end
end
