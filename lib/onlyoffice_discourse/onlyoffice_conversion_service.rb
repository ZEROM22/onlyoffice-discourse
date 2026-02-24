# frozen_string_literal: true
require "net/http"
require "openssl"

module Onlyoffice
  class ConversionService
    def initialize(upload_short_url:, target_format:)
      @upload_short_url = upload_short_url
      @target_format = target_format
    end

    def convert
      validate_parameters!

      file_url = get_file_url
      raise "File not found" if file_url.blank?

      full_file_url = build_full_url(file_url)
      converted_file_url = request_conversion(full_file_url, file_url)

      original_filename = File.basename(file_url, ".*")
      { download_url: converted_file_url, filename: "#{original_filename}.#{@target_format}" }
    end

    private

    def validate_parameters!
      raise "Missing parameters" unless @upload_short_url && @target_format
    end

    def get_file_url
      file_url = ""
      PrettyText::Helpers
        .lookup_upload_urls([@upload_short_url])
        .each { |short_url, paths| file_url = paths[:url] }
      file_url
    end

    def build_full_url(file_url)
      "#{SiteSetting.Server_address_for_internal_requests_from_ONLYOFFICE_Docs}#{file_url}"
    end

    def request_conversion(full_file_url, file_url)
      ds_internal_host = SiteSetting.ONLYOFFICE_Docs_address_for_internal_requests_from_the_server
      conversion_url = "#{ds_internal_host}/ConvertService.ashx"

      conversion_request = {
        url: full_file_url,
        outputtype: @target_format,
        filetype: File.extname(file_url).delete(".").downcase,
        title: File.basename(file_url, ".*"),
        async: false,
      }

      if Onlyoffice::OnlyofficeJwt.enabled?
        conversion_request[:token] = Onlyoffice::OnlyofficeJwt.encode(conversion_request)
      end

      uri = URI(conversion_url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.verify_mode = OpenSSL::SSL::VERIFY_NONE if Rails.env.development?

      request = Net::HTTP::Post.new(uri.path)
      request["Content-Type"] = "application/json"
      request["Accept"] = "application/json"
      request.body = conversion_request.to_json

      response = http.request(request)
      result = JSON.parse(response.body)

      raise "Conversion failed: #{result["error"]}" if result["error"]

      raise "Conversion failed: no file URL returned" unless result["fileUrl"]

      result["fileUrl"]
    end
  end
end
