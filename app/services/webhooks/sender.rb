require "ipaddr"
require "net/http"
require "resolv"

module Webhooks
  class Sender
    Retryable = Class.new(StandardError)
    NON_PUBLIC_RANGES = %w[
      0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16
      172.16.0.0/12 192.0.0.0/24 192.0.2.0/24 192.168.0.0/16 198.18.0.0/15
      198.51.100.0/24 203.0.113.0/24 224.0.0.0/4 240.0.0.0/4
      ::/128 ::1/128 fc00::/7 fe80::/10 ff00::/8 2001:db8::/32
    ].map { |range| IPAddr.new(range) }.freeze
    class_attribute :resolver, default: ->(host) { Resolv.getaddresses(host) }

    def self.call(delivery)
      return if delivery.delivered?

      uri = Target.validate_url!(delivery.url)
      body = JSON.generate(delivery.payload)
      timestamp = Time.current.to_i.to_s
      secret = SecretBox.decrypt(delivery.secret_ciphertext)
      signed = "#{delivery.event_id}.#{timestamp}.#{body}"
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request["User-Agent"] = "Printwright-Webhooks/1.0"
      request["Webhook-Id"] = delivery.event_id
      request["Webhook-Timestamp"] = timestamp
      request["Webhook-Signature"] = "v1=#{OpenSSL::HMAC.hexdigest('SHA256', secret, signed)}"
      request.body = body

      delivery.increment!(:attempts)
      http = Net::HTTP.new(uri.host, 443)
      http.ipaddr = public_address(uri.host)
      http.use_ssl = true
      http.open_timeout = 5
      http.read_timeout = 10
      response = http.start { |client| client.request(request) }
      raise Retryable, "callback returned HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      delivery.update!(
        status: "delivered", delivered_at: Time.current,
        response_code: response.code.to_i, last_error: nil
      )
    rescue Target::Invalid, ActiveSupport::MessageEncryptor::InvalidMessage,
           Timeout::Error, SocketError, SystemCallError, OpenSSL::SSL::SSLError,
           Resolv::ResolvError, IPAddr::InvalidAddressError => error
      raise Retryable, error.message
    end

    def self.public_address(host)
      addresses = resolver.call(host)
      raise Retryable, "callback host did not resolve" if addresses.empty?
      if addresses.any? { |address| NON_PUBLIC_RANGES.any? { |range| range.include?(IPAddr.new(address)) } }
        raise Retryable, "callback host resolved to a non-public address"
      end
      addresses.first
    end
    private_class_method :public_address
  end
end
