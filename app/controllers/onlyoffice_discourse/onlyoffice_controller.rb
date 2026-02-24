# frozen_string_literal: true
require "open-uri"
require "json"
require "fileutils"
require "net/http"
require "openssl"
require "tempfile"
require "zip"
require "securerandom"

class Onlyoffice::OnlyofficeController < ::ApplicationController
  include Onlyoffice::ControllerExtensions

  requires_login except: %i[callback formats editor demo_info]
  protect_from_forgery except: %i[callback formats demo_info]
  skip_before_action :verify_authenticity_token, only: %i[callback formats demo_info]
  skip_before_action :redirect_to_login_if_required, only: %i[formats callback editor demo_info]
  skip_before_action :check_xhr, only: %i[formats editor callback convert demo_info]
  skip_before_action :preload_json, only: [:callback]
  skip_before_action :redirect_to_profile_if_required, only: [:callback]

  def formats
    formats_file =
      File.join(
        File.dirname(__FILE__),
        "..",
        "..",
        "..",
        "assets",
        "document_formats",
        "onlyoffice-docs-formats.json",
      )

    if File.exist?(formats_file)
      render plain: File.read(formats_file), content_type: "application/json"
    else
      render json: []
    end
  end

  def demo_info
    data = Onlyoffice::OnlyofficeDemo.demo_data
    expiration_date = Onlyoffice::OnlyofficeDemo.expiration_date

    render json: {
             enabled: data[:enabled],
             available: data[:available],
             days_remaining: Onlyoffice::OnlyofficeDemo.days_remaining,
             expiration_date: expiration_date ? expiration_date.iso8601 : nil,
           }
  end

  def create
    document_type = params[:document_type] || "docx"
    locale = params[:locale] || "en"
    custom_filename = params[:filename].to_s.strip

    if %w[docx xlsx pptx pdf].exclude?(document_type)
      return render json: { error: "Invalid document type" }, status: :bad_request
    end

    template_path = get_template_path(locale, document_type)

    unless File.exist?(template_path)
      return render json: { error: "Template not found" }, status: :not_found
    end

    begin
      # Generate filename from user input or timestamp
      safe_filename =
        if custom_filename.present?
          FileHelper.sanitize_filename(custom_filename).sub(/\.(docx|xlsx|pptx|pdf)$/i, "")
        else
          ""
        end

      filename =
        if safe_filename.present?
          "#{safe_filename}.#{document_type}"
        else
          "document_#{Time.now.strftime("%Y%m%d_%H%M%S")}.#{document_type}"
        end

      # Create temp file with correct filename
      temp_dir = Dir.tmpdir
      temp_path = File.join(temp_dir, filename)

      # Make file unique by modifying metadata
      unique_id = SecureRandom.uuid
      timestamp = Time.now.iso8601

      if %w[docx xlsx pptx].include?(document_type)
        # Office files are ZIP archives - modify core properties to make each file unique
        # Copy template
        FileUtils.cp(template_path, temp_path)

        begin
          # Modify the core.xml properties to make file unique
          Zip::File.open(temp_path) do |zip_file|
            core_props_path = "docProps/core.xml"

            if zip_file.find_entry(core_props_path)
              # Read existing core properties
              core_xml = zip_file.read(core_props_path)

              # Update created/modified timestamps and add unique identifier
              core_xml =
                core_xml.gsub(
                  %r{<dcterms:created[^>]*>.*?</dcterms:created>},
                  "<dcterms:created xsi:type=\"dcterms:W3CDTF\">#{timestamp}</dcterms:created>",
                )
              core_xml =
                core_xml.gsub(
                  %r{<dcterms:modified[^>]*>.*?</dcterms:modified>},
                  "<dcterms:modified xsi:type=\"dcterms:W3CDTF\">#{timestamp}</dcterms:modified>",
                )

              # Add unique identifier as subject if not exists
              if core_xml.exclude?("<dc:subject>")
                core_xml =
                  core_xml.gsub(
                    "</cp:coreProperties>",
                    "<dc:subject>discourse-#{unique_id}</dc:subject></cp:coreProperties>",
                  )
              end

              # Write back modified XML
              zip_file.get_output_stream(core_props_path) { |f| f.write(core_xml) }
            end
          end
        rescue => e
          Rails.logger.error("Failed to modify Office file metadata: #{e.message}")
          # If modification fails, use template as is (will be deduplicated)
        end
      elsif document_type == "pdf"
        # For PDF, append unique metadata to make each file unique
        # Read template content
        pdf_content = File.binread(template_path)

        # Add unique XMP metadata comment at the end of PDF
        # This doesn't affect PDF rendering but makes the file unique
        unique_metadata = "\n%discourse-id:#{unique_id}\n%timestamp:#{timestamp}\n%%EOF\n"

        # Write modified PDF
        File.open(temp_path, "wb") do |f|
          # Remove trailing %%EOF if present and add our metadata before new %%EOF
          if pdf_content.end_with?("%%EOF\n")
            f.write(pdf_content.chomp("%%EOF\n"))
          elsif pdf_content.end_with?("%%EOF")
            f.write(pdf_content.chomp("%%EOF"))
          else
            f.write(pdf_content)
          end
          f.write(unique_metadata)
        end
      end

      upload =
        UploadCreator.new(
          File.open(temp_path),
          filename,
          type: "composer",
          for_private_message: false,
        ).create_for(current_user.id)

      File.delete(temp_path) if File.exist?(temp_path)

      if upload.persisted?
        render json: UploadSerializer.new(upload, root: nil).as_json
      else
        render json: {
                 error: upload.errors.full_messages.join(", "),
               },
               status: :unprocessable_entity
      end
    rescue => e
      render json: { error: e.message }, status: :internal_server_error
    end
  end

  def editor
    upload_id = params[:id].to_s.sub(/\.json$/, "")

    # Check if demo mode is enabled but expired
    demo_data = Onlyoffice::OnlyofficeDemo.demo_data
    if demo_data[:enabled] && !demo_data[:available]
      return(
        render json: {
                 error: I18n.t("site_settings.onlyoffice_connector.demo.expired_error"),
                 demo_expired: true,
               },
               status: :forbidden
      )
    end

    if request.format.json?
      upload = find_upload_by_short_url(upload_id)

      # Determine access mode based on user permissions
      if current_user.nil?
        # Anonymous users can only view
        is_view = true
      else
        # Check user permission (owner/staff = editor, custom permission, or default viewer)
        user_permission = check_user_permission(upload, current_user)
        is_view = (user_permission == "viewer")
      end

      file_url = +""

      PrettyText::Helpers
        .lookup_upload_urls([upload_id])
        .each { |short_url, paths| file_url << paths[:url] }

      # Get file extension from upload object
      file_extension = upload.extension || File.extname(file_url).delete(".").downcase
      file_extension = File.extname(upload_id).delete(".").downcase if file_extension.blank?

      # Get filename from upload object
      file_title = upload.original_filename || File.basename(file_url)

      # Validate extension
      if file_extension.blank?
        return render json: { error: "Cannot determine file type" }, status: :bad_request
      end

      document_type =
        case file_extension
        when "doc", "docx", "docm", "dot", "dotx", "dotm", "odt", "fodt", "ott", "rtf", "txt",
             "html", "htm", "mht", "pdf", "djvu", "fb2", "epub", "xps"
          "word"
        when "xls", "xlsx", "xlsm", "xlt", "xltx", "xltm", "ods", "fods", "ots", "csv"
          "cell"
        when "pps", "ppsx", "ppsm", "ppt", "pptx", "pptm", "pot", "potx", "potm", "odp", "fodp",
             "otp"
          "slide"
        else
          "word"
        end

      # Generate unique key for document version
      # Include upload timestamp to force reload when file is updated
      doc_key = "#{upload_id}_#{upload.updated_at.to_i}"

      doc_config = {
        type: "desktop",
        documentType: document_type,
        document: {
          title: file_title,
          url: SiteSetting.Server_address_for_internal_requests_from_ONLYOFFICE_Docs + file_url,
          fileType: file_extension,
          key: doc_key,
          permissions: {
            edit: !is_view,
          },
        },
        editorConfig: {
          mode: is_view ? "view" : "edit",
          lang: get_user_locale,
          callbackUrl:
            "#{SiteSetting.Server_address_for_internal_requests_from_ONLYOFFICE_Docs}/onlyoffice/callback/#{upload_id}",
          user:
            (
              if current_user
                {
                  id: current_user.id,
                  name: current_user.name ? current_user.name : current_user.username,
                }
              else
                { id: "guest", name: "Guest" }
              end
            ),
          customization: {
            forcesave: false,
          },
        },
      }

      if Onlyoffice::OnlyofficeJwt.enabled?
        doc_config[:token] = Onlyoffice::OnlyofficeJwt.generate_editor_token(doc_config)
      end

      response_data = {
        config: {
          ds_host: SiteSetting.ONLYOFFICE_Docs_address,
        },
        id: params[:id],
        doc_config: doc_config,
      }

      # Add demo mode info if enabled
      if demo_data[:enabled] && demo_data[:available]
        expiration_date = Onlyoffice::OnlyofficeDemo.expiration_date
        response_data[:demo_mode] = {
          enabled: true,
          days_remaining: Onlyoffice::OnlyofficeDemo.days_remaining,
          expiration_date: expiration_date ? expiration_date.iso8601 : nil,
        }
      end

      render json: response_data
    else
      render "default/empty", formats: [:html]
    end
  end

  def callback
    if request.get?
      render json: { error: 0 }
      return
    end

    file_data = read_callback_body

    if file_data.nil?
      render json: { error: 1, message: "Invalid request" }, status: :bad_request
      return
    end

    response_json = { error: 0, message: "" }

    begin
      upload_id = params[:id].to_s.sub(/\.json$/, "")
      status = file_data["status"].to_i

      case status
      when 0
        # Document not found
        response_json[
          :message
        ] = "ONLYOFFICE has reported that no doc with the specified key can be found"
      when 1
        response_json[:message] = "User has entered/exited ONLYOFFICE"
      when 2, 3
        # MustSave (2) or Corrupted (3) - save the document
        saved = process_save(file_data, upload_id)
        response_json[:error] = saved
        response_json[:message] = (
          if saved == 0
            "Document saved successfully"
          else
            "Error saving document"
          end
        )
      when 4
        # No document updates
        response_json[:message] = "No document updates"
      when 6, 7
        # MustForcesave (6) or CorruptedForcesave (7)
        saved = process_force_save(file_data, upload_id)
        response_json[:error] = saved
        response_json[:message] = (
          if saved == 0
            "Document force saved successfully"
          else
            "Error force saving document"
          end
        )
      else
        response_json[:message] = "Unknown status: #{status}"
      end
    rescue => exception
      response_json[:message] = exception.message
      response_json[:error] = 1
    ensure
      unless performed?
        render json: response_json,
               status: response_json[:error] == 1 ? :internal_server_error : :ok
      end
    end
  end

  private

  def read_callback_body
    body = request.body.read
    return nil if body.blank?

    file_data = JSON.parse(body)

    if Onlyoffice::OnlyofficeJwt.enabled?
      in_header = false
      token = nil
      jwt_header = SiteSetting.JWT_header || "Authorization"

      if file_data["token"]
        token = Onlyoffice::OnlyofficeJwt.decode(file_data["token"])
      elsif request.headers[jwt_header]
        hdr = request.headers[jwt_header].to_s
        hdr = hdr.sub(/^Bearer /, "")
        token = Onlyoffice::OnlyofficeJwt.decode(hdr)
        in_header = true
      else
        raise "Expected JWT"
      end

      raise "Invalid JWT signature" if token.nil? || token == ""

      file_data = JSON.parse(token)
      file_data = file_data["payload"] if in_header
    end

    file_data
  rescue => e
    Rails.logger.error("JWT validation failed: #{e.message}")
    nil
  end

  def get_user_locale
    return SiteSetting.default_locale unless current_user
    if SiteSetting.allow_user_locale && current_user.locale
      current_user.locale
    else
      SiteSetting.default_locale
    end
  end

  def process_save(data, upload_id)
    upload_id = upload_id.to_s.sub(/\.json$/, "")
    download_uri = data["url"]

    return 1 if download_uri.blank?

    file_content = download_file_from_onlyoffice(download_uri)
    return 1 unless file_content

    save_file_to_upload(upload_id, file_content)
  rescue => e
    Rails.logger.error("ONLYOFFICE: Document save failed - #{e.class}: #{e.message}")
    1
  end

  def download_file_from_onlyoffice(download_uri)
    # Replace ONLYOFFICE internal IP with configured host
    internal_host = SiteSetting.ONLYOFFICE_Docs_address_for_internal_requests_from_the_server
    if internal_host.present? && download_uri =~ %r{^https?://[\d.]+[:/]}
      download_uri = download_uri.sub(%r{^https?://[\d.]+}, internal_host.sub(%r{/$}, ""))
    end

    uri = URI.parse(download_uri)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true if uri.scheme == "https"
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE if uri.scheme == "https"
    http.open_timeout = 10
    http.read_timeout = 30

    response = http.request(Net::HTTP::Get.new(uri.request_uri))

    unless response.is_a?(Net::HTTPSuccess)
      Rails.logger.error("ONLYOFFICE: Failed to download file - HTTP #{response.code}")
      return nil
    end

    file_content = response.body
    (file_content.presence)
  end

  def save_file_to_upload(upload_id, file_content)
    sha1 = find_sha1_from_upload_id(upload_id)
    unless sha1
      Rails.logger.error("ONLYOFFICE: Could not find SHA1 for upload: #{upload_id}")
      return 1
    end

    upload = Upload.find_by(sha1: sha1)
    unless upload
      Rails.logger.error("ONLYOFFICE: Could not find upload with SHA1: #{sha1}")
      return 1
    end

    path = Discourse.store.path_for(upload)
    unless path && File.exist?(path)
      Rails.logger.error("ONLYOFFICE: File path not found: #{path}")
      return 1
    end

    File.binwrite(path, file_content)
    upload.update!(filesize: file_content.bytesize)
    0
  end

  def process_force_save(data, upload_id)
    process_save(data, upload_id)
  end

  def find_sha1_from_upload_id(upload_id)
    [upload_id, upload_id.sub(/\.[^.]+$/, "")].each do |id|
      PrettyText::Helpers
        .lookup_upload_urls([id])
        .each { |_, info| return $1 if info[:url] =~ /\/([a-f0-9]{40})\./ }
    end
    nil
  end

  def get_template_path(locale, document_type)
    plugin_path = File.expand_path("../../../..", __FILE__)
    templates_dir = File.join(plugin_path, "assets", "document_templates")
    normalized_locale = normalize_locale(locale)

    locale_path = File.join(templates_dir, normalized_locale, "new.#{document_type}")
    return locale_path if File.exist?(locale_path)

    base_locale = locale.split("-").first
    base_locale_dirs = Dir.glob(File.join(templates_dir, "#{base_locale}-*"))

    base_locale_dirs.each do |dir|
      path = File.join(dir, "new.#{document_type}")
      return path if File.exist?(path)
    end

    File.join(templates_dir, "default", "new.#{document_type}")
  end

  def normalize_locale(locale)
    # Convert Discourse locale format to ONLYOFFICE format
    # Special cases that don't follow the pattern
    special_cases = { "pt" => "pt-BR", "zh_CN" => "zh-CN", "zh_TW" => "zh-TW", "nb_NO" => "nb-NO" }

    return special_cases[locale] if special_cases.key?(locale)

    # Standard pattern: "en" => "en-US", "ru" => "ru-RU", etc.
    # If locale already has format "xx-YY", return as is
    return locale if locale.include?("-")

    # Convert "en" to "en-US" pattern
    country_codes = {
      "en" => "US",
      "ru" => "RU",
      "de" => "DE",
      "fr" => "FR",
      "es" => "ES",
      "it" => "IT",
      "ja" => "JP",
      "ko" => "KR",
      "ar" => "SA",
      "pl" => "PL",
      "nl" => "NL",
      "tr" => "TR",
      "uk" => "UA",
      "cs" => "CZ",
      "sv" => "SE",
      "da" => "DK",
      "fi" => "FI",
      "he" => "IL",
      "hu" => "HU",
      "ro" => "RO",
      "bg" => "BG",
      "sk" => "SK",
      "el" => "GR",
      "vi" => "VN",
      "id" => "ID",
      "ms" => "MY",
      "th" => "TH",
    }

    country = country_codes[locale] || locale.upcase
    "#{locale}-#{country}"
  end
end
