# frozen_string_literal: true
class CreateOnlyofficePermissions < ActiveRecord::Migration[7.0]
  def change
    create_table :onlyoffice_permissions do |t|
      t.integer :upload_id, null: false
      t.integer :user_id, null: false
      t.string :permission_type, null: false, default: "viewer"
      t.timestamps
    end

    add_index :onlyoffice_permissions, %i[upload_id user_id], unique: true
    add_index :onlyoffice_permissions, :upload_id
    add_index :onlyoffice_permissions, :user_id
  end
end
