# frozen_string_literal: true

module Onlyoffice
  class OnlyofficeDemo
    DEMO_ADDR = "https://onlinedocs.docs.onlyoffice.com"
    DEMO_HEADER = "AuthorizationJWT"
    DEMO_SECRET = "sn2puSUF7muF5Jas"
    DEMO_TRIAL_DAYS = 30

    def self.demo_data
      data_json = PluginStore.get(Onlyoffice::PLUGIN_NAME, "demo_data")

      return { available: true, enabled: false, start: nil } if data_json.nil?

      data = JSON.parse(data_json, symbolize_names: true)

      if data[:start]
        start_date = Time.parse(data[:start])
        overdue_date = start_date + (DEMO_TRIAL_DAYS * 24 * 60 * 60)

        if overdue_date > Time.now
          data[:available] = true
        else
          data[:available] = false
        end
      else
        data[:available] = true
      end

      data
    end

    def self.enable_demo(value)
      data = demo_data

      if value && !data[:available]
        Rails.logger.info("ONLYOFFICE: Trial demo is overdue")
        return false
      end

      data[:enabled] = value
      data[:start] ||= Time.now.iso8601 if value

      PluginStore.set(Onlyoffice::PLUGIN_NAME, "demo_data", data.to_json)

      # Update site settings
      if value
        # Save current settings before enabling demo
        unless data[:saved_settings]
          data[:saved_settings] = {
            address: SiteSetting.ONLYOFFICE_Docs_address,
            secret: SiteSetting.ONLYOFFICE_Docs_secret_key,
            header: SiteSetting.JWT_header,
          }
          PluginStore.set(Onlyoffice::PLUGIN_NAME, "demo_data", data.to_json)
        end

        # Set demo values
        SiteSetting.Connect_to_demo_ONLYOFFICE_Docs_server = true
        SiteSetting.ONLYOFFICE_Docs_address = DEMO_ADDR
        SiteSetting.ONLYOFFICE_Docs_secret_key = DEMO_SECRET
        SiteSetting.JWT_header = DEMO_HEADER
      else
        # Restore saved settings when demo disabled
        if data[:saved_settings]
          SiteSetting.ONLYOFFICE_Docs_address =
            data[:saved_settings][:address] || "http://localhost"
          SiteSetting.ONLYOFFICE_Docs_secret_key = data[:saved_settings][:secret] || ""
          SiteSetting.JWT_header = data[:saved_settings][:header] || "Authorization"

          # Clear saved settings
          data[:saved_settings] = nil
          PluginStore.set(Onlyoffice::PLUGIN_NAME, "demo_data", data.to_json)
        end

        SiteSetting.Connect_to_demo_ONLYOFFICE_Docs_server = false
      end

      true
    end

    def self.demo_enabled?
      demo_data[:enabled] == true
    end

    def self.demo_available?
      demo_data[:available] == true
    end

    def self.days_remaining
      data = demo_data
      return nil unless data[:start]

      start_date = Time.parse(data[:start])
      overdue_date = start_date + (DEMO_TRIAL_DAYS * 24 * 60 * 60)
      days = ((overdue_date - Time.now) / (24 * 60 * 60)).ceil

      [days, 0].max
    end

    def self.expiration_date
      data = demo_data
      return nil unless data[:start]

      start_date = Time.parse(data[:start])
      start_date + (DEMO_TRIAL_DAYS * 24 * 60 * 60)
    end
  end
end
