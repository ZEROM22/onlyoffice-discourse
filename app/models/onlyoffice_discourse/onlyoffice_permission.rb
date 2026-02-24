# frozen_string_literal: true
module Onlyoffice
  class Permission < ActiveRecord::Base
    self.table_name = "onlyoffice_permissions"

    belongs_to :upload
    belongs_to :user

    validates :upload_id, presence: true
    validates :user_id, presence: true
    validates :permission_type, inclusion: { in: %w[viewer editor] }
    validates :user_id, uniqueness: { scope: :upload_id }

    VIEWER = "viewer"
    EDITOR = "editor"
  end
end
