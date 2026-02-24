# frozen_string_literal: true

require "jwt"

module Onlyoffice
  class OnlyofficeJwt
    def self.enabled?
      SiteSetting.ONLYOFFICE_Docs_secret_key.present?
    end

    def self.encode(payload)
      return nil unless enabled?
      JWT.encode(payload, SiteSetting.ONLYOFFICE_Docs_secret_key, "HS256")
    end

    def self.decode(token)
      return nil unless enabled? || token.blank?

      decoded =
        JWT.decode(token, SiteSetting.ONLYOFFICE_Docs_secret_key, true, { algorithm: "HS256" })[0]
      decoded.to_json
    rescue JWT::DecodeError => e
      Rails.logger.error("JWT decode failed: #{e.message}")
      nil
    end

    def self.generate_editor_token(config)
      encode(config)
    end
  end
end
