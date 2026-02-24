# frozen_string_literal: true

module Onlyoffice
  module ControllerExtensions
    def convert
      begin
        service =
          Onlyoffice::ConversionService.new(
            upload_short_url: params[:upload_short_url],
            target_format: params[:target_format],
          )

        result = service.convert
        render json: result
      rescue => e
        render json: { error: e.message }, status: :internal_server_error
      end
    end

    def upload_info
      upload_short_url = params[:id]

      upload = nil
      PrettyText::Helpers
        .lookup_upload_urls([upload_short_url])
        .each do |short_url, paths|
          if paths[:base62_sha1]
            sha1 = Upload.sha1_from_base62_encoded(paths[:base62_sha1])
            upload = Upload.find_by(sha1: sha1)
          elsif paths[:sha1]
            upload = Upload.find_by(sha1: paths[:sha1])
          end
        end

      if upload
        render json: { upload_id: upload.id, user_id: upload.user_id }
      else
        render json: { error: "Upload not found" }, status: :not_found
      end
    end

    def list_permissions
      upload = find_upload_by_short_url(params[:id])
      return render json: { error: "Upload not found" }, status: :not_found unless upload
      unless can_manage_permissions?(upload)
        return render json: { error: "Access denied" }, status: :forbidden
      end

      permissions = Onlyoffice::Permission.where(upload_id: upload.id).includes(:user)

      render json: {
               permissions:
                 permissions.map do |p|
                   {
                     id: p.id,
                     user: {
                       id: p.user.id,
                       username: p.user.username,
                       name: p.user.name,
                       avatar_template: p.user.avatar_template,
                     },
                     permission_type: p.permission_type,
                   }
                 end,
             }
    end

    def create_permission
      upload = find_upload_by_short_url(params[:id])
      return render json: { error: "Upload not found" }, status: :not_found unless upload
      unless can_manage_permissions?(upload)
        return render json: { error: "Access denied" }, status: :forbidden
      end

      permission =
        Onlyoffice::Permission.new(
          upload_id: upload.id,
          user_id: params[:user_id],
          permission_type: params[:permission_type],
        )

      if permission.save
        render json: { success: true }
      else
        render json: {
                 error: permission.errors.full_messages.join(", "),
               },
               status: :unprocessable_entity
      end
    end

    def update_permission
      upload = find_upload_by_short_url(params[:id])
      return render json: { error: "Upload not found" }, status: :not_found unless upload
      unless can_manage_permissions?(upload)
        return render json: { error: "Access denied" }, status: :forbidden
      end

      permission = Onlyoffice::Permission.find_by(id: params[:permission_id], upload_id: upload.id)
      return render json: { error: "Permission not found" }, status: :not_found unless permission

      if permission.update(permission_type: params[:permission_type])
        render json: { success: true }
      else
        render json: {
                 error: permission.errors.full_messages.join(", "),
               },
               status: :unprocessable_entity
      end
    end

    def delete_permission
      upload = find_upload_by_short_url(params[:id])
      return render json: { error: "Upload not found" }, status: :not_found unless upload
      unless can_manage_permissions?(upload)
        return render json: { error: "Access denied" }, status: :forbidden
      end

      permission = Onlyoffice::Permission.find_by(id: params[:permission_id], upload_id: upload.id)
      return render json: { error: "Permission not found" }, status: :not_found unless permission

      if permission.destroy
        render json: { success: true }
      else
        render json: { error: "Failed to delete permission" }, status: :internal_server_error
      end
    end

    private

    def find_upload_by_short_url(short_url)
      upload = nil
      PrettyText::Helpers
        .lookup_upload_urls([short_url])
        .each do |_, paths|
          if paths[:base62_sha1]
            sha1 = Upload.sha1_from_base62_encoded(paths[:base62_sha1])
            upload = Upload.find_by(sha1: sha1)
          elsif paths[:sha1]
            upload = Upload.find_by(sha1: paths[:sha1])
          end
        end
      upload
    end

    def check_user_permission(upload, user)
      return "editor" unless upload

      # Owner always has editor rights
      return "editor" if upload.user_id == user.id

      # Check explicit permissions set by owner
      permission = Onlyoffice::Permission.find_by(upload_id: upload.id, user_id: user.id)
      return permission.permission_type if permission

      # Everyone else (including staff) gets viewer by default
      "viewer"
    end

    def can_manage_permissions?(upload)
      return false unless current_user

      # Check if user is post author (if post_id provided)
      if params[:post_id].present?
        post = Post.find_by(id: params[:post_id])
        return true if post && post.user_id == current_user.id
      end

      # Only upload owner can manage permissions
      return true if upload.user_id == current_user.id

      false
    end
  end
end
