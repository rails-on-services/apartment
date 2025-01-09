# frozen_string_literal: true

class CreateUsers < ActiveRecord::Migration[Rails::VERSION::STRING.to_f]
  def change
    create_table(:users) do |t|
      t.string(:name, null: false)
      t.string(:email, null: false)

      t.timestamps
    end

    add_index(:users, :email, unique: true)
  end
end
