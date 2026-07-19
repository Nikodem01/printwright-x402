module Webhooks
  module Target
    Invalid = Class.new(StandardError)

    def self.validate!(url:, secret:)
      validate_url!(url)
      raise Invalid, "secret must be 32 to 256 bytes" unless secret.to_s.bytesize.between?(32, 256)

      true
    end

    def self.validate_url!(value)
      uri = URI.parse(value.to_s)
      unless uri.is_a?(URI::HTTPS) && uri.port == 443 && uri.host.present? && uri.userinfo.nil? &&
          uri.fragment.nil? && value.to_s.bytesize <= 2_048
        raise Invalid, "must be a public HTTPS URL on port 443 without credentials or a fragment"
      end
      uri
    rescue URI::InvalidURIError
      raise Invalid, "is invalid"
    end
  end
end
