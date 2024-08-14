# frozen_string_literal: true

class CreatePublicTokens < ActiveRecord::Migration[4.2]
  def up
    create_table :public_tokens do |t|
      t.string :token
      t.integer :user_id, foreign_key: true
    end
  end

  def down
    drop_table :public_tokens
  end
end
