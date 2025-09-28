# frozen_string_literal: true

class CreateCompanies < ActiveRecord::Migration[Rails::VERSION::STRING.to_f]
  def change
    create_table(:companies) do |t|
      t.string(:name, null: false)
      t.string(:subdomain, null: false)

      t.timestamps
    end

    add_index(:companies, :subdomain, unique: true)
  end
end
