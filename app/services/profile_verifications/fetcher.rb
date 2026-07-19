require "ipaddr"
require "net/http"
require "resolv"

module ProfileVerifications
  class Fetcher
    Error = Class.new(StandardError)
    ALLOWED_HOSTS = %w[
      github.com www.github.com printables.com www.printables.com
      makerworld.com www.makerworld.com thingiverse.com www.thingiverse.com
      cults3d.com www.cults3d.com
    ].freeze
    MAX_BODY = 1.megabyte
    class_attribute :resolver, default: ->(host) { Resolv.getaddresses(host) }
    NON_PUBLIC_RANGES = %w[
      0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16
      172.16.0.0/12 192.0.0.0/24 192.0.2.0/24 192.168.0.0/16 198.18.0.0/15
      198.51.100.0/24 203.0.113.0/24 224.0.0.0/4 240.0.0.0/4
      ::/128 ::1/128 fc00::/7 fe80::/10 ff00::/8 2001:db8::/32
    ].map { |range| IPAddr.new(range) }.freeze

    class << self
      def call(profile_verification)
        if profile_verification.expires_at.past?
          profile_verification.update!(status: "expired", last_error: "challenge expired")
          raise Error, "challenge expired; create a new one"
        end

        body = fetch(validate_uri!(profile_verification.profile_url))
        unless body.include?(profile_verification.challenge_token)
          profile_verification.update!(status: "failed", last_error: "proof token is not visible in the public profile")
          raise Error, profile_verification.last_error
        end
        verify_signature!(profile_verification)
        profile_verification.transaction do
          profile_verification.update!(status: "verified", verified_at: Time.current, last_error: nil)
          profile_verification.designer.update!(
            verified: true, identity_verified_at: Time.current,
            verified_profile_url: profile_verification.profile_url
          )
        end
        true
      rescue ActiveSupport::MessageVerifier::InvalidSignature
        raise Error, "proof token signature is invalid or expired"
      end

      def validate_uri!(value)
        uri = URI.parse(value.to_s)
        unless uri.is_a?(URI::HTTPS) && uri.port == 443 && uri.userinfo.nil? && ALLOWED_HOSTS.include?(uri.host)
          raise Error, "use a public HTTPS profile on GitHub, Printables, MakerWorld, Thingiverse, or Cults3D"
        end
        public_address(uri.host)
        uri.fragment = nil
        uri
      rescue URI::InvalidURIError
        raise Error, "profile URL is invalid"
      end

      private

      def fetch(uri, redirects = 0)
        raise Error, "too many profile redirects" if redirects > 2

        request = Net::HTTP::Get.new(uri)
        request["User-Agent"] = "Printwright-Identity-Verification/1.0"
        http = Net::HTTP.new(uri.host, 443)
        http.ipaddr = public_address(uri.host)
        http.use_ssl = true
        http.open_timeout = 5
        http.read_timeout = 8
        response = http.start { |client| client.request(request) }
        if response.is_a?(Net::HTTPRedirection)
          return fetch(validate_uri!(URI.join(uri, response.fetch("location")).to_s), redirects + 1)
        end
        raise Error, "profile returned HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)
        raise Error, "profile response exceeds 1 MB" if response.body.to_s.bytesize > MAX_BODY

        response.body.to_s
      rescue Timeout::Error, SocketError, SystemCallError, OpenSSL::SSL::SSLError => error
        raise Error, "profile could not be fetched (#{error.class.name.demodulize})"
      end

      def verify_signature!(verification)
        signed = verification.challenge_token.delete_prefix("printwright-proof:")
        payload = Rails.application.message_verifier("designer-profile").verify(signed)
        designer_id = payload[:designer_id] || payload["designer_id"]
        raise Error, "proof belongs to another designer" unless designer_id == verification.designer_id
      end

      def public_address(host)
        addresses = resolver.call(host)
        raise Error, "profile host did not resolve" if addresses.empty?
        if addresses.any? { |address| NON_PUBLIC_RANGES.any? { |range| range.include?(IPAddr.new(address)) } }
          raise Error, "profile host resolved to a non-public address"
        end
        addresses.first
      rescue Resolv::ResolvError, IPAddr::InvalidAddressError
        raise Error, "profile host did not resolve safely"
      end
    end
  end
end
