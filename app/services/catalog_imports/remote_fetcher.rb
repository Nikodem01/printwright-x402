require "ipaddr"
require "net/http"
require "resolv"

module CatalogImports
  class RemoteFetcher
    MAX_REDIRECTS = 2
    NON_PUBLIC_RANGES = %w[
      0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16
      172.16.0.0/12 192.0.0.0/24 192.0.2.0/24 192.168.0.0/16 198.18.0.0/15
      198.51.100.0/24 203.0.113.0/24 224.0.0.0/4 240.0.0.0/4
      ::/128 ::1/128 fc00::/7 fe80::/10 ff00::/8 2001:db8::/32
    ].map { |range| IPAddr.new(range) }.freeze

    class_attribute :resolver, default: ->(host) { Resolv.getaddresses(host) }

    class << self
      def call(url, max_bytes:, accept: "application/octet-stream")
        fetch(validate_url!(url), max_bytes: max_bytes, accept: accept)
      end

      def validate_url!(value)
        uri = URI.parse(value.to_s)
        unless uri.is_a?(URI::HTTPS) && uri.port == 443 && uri.host.present? &&
            uri.userinfo.nil? && uri.fragment.nil? && value.to_s.bytesize <= 2_048
          raise Error, "remote URLs must use public HTTPS on port 443 without credentials or fragments"
        end
        public_address(uri.host)
        uri
      rescue URI::InvalidURIError
        raise Error, "remote URL is invalid"
      end

      private

      def fetch(uri, max_bytes:, accept:, redirects: 0)
        raise Error, "too many remote redirects" if redirects > MAX_REDIRECTS

        request = Net::HTTP::Get.new(uri)
        request["Accept"] = accept
        request["User-Agent"] = "Printwright-Catalog-Import/1.0"
        redirect = nil
        result = nil
        http = Net::HTTP.new(uri.host, 443)
        http.ipaddr = public_address(uri.host)
        http.use_ssl = true
        http.open_timeout = 5
        http.read_timeout = 15
        http.start do |client|
          client.request(request) do |response|
            if response.is_a?(Net::HTTPRedirection)
              redirect = response["location"] || raise(Error, "remote redirect has no location")
            else
              raise Error, "remote URL returned HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)
              if response["content-length"].to_i > max_bytes
                raise Error, "remote response exceeds #{max_bytes / 1.megabyte} MB"
              end

              result = String.new(capacity: [ max_bytes, 1.megabyte ].min, encoding: Encoding::BINARY)
              response.read_body do |chunk|
                result << chunk
                raise Error, "remote response exceeds #{max_bytes / 1.megabyte} MB" if result.bytesize > max_bytes
              end
            end
          end
        end
        return result unless redirect

        target = validate_url!(URI.join(uri, redirect).to_s)
        fetch(target, max_bytes: max_bytes, accept: accept, redirects: redirects + 1)
      rescue Timeout::Error, SocketError, SystemCallError, OpenSSL::SSL::SSLError => error
        raise Error, "remote URL could not be fetched (#{error.class.name.demodulize})"
      end

      def public_address(host)
        addresses = resolver.call(host)
        raise Error, "remote host did not resolve" if addresses.empty?
        if addresses.any? { |address| NON_PUBLIC_RANGES.any? { |range| range.include?(IPAddr.new(address)) } }
          raise Error, "remote host resolved to a non-public address"
        end
        addresses.first
      rescue Resolv::ResolvError, IPAddr::InvalidAddressError
        raise Error, "remote host did not resolve safely"
      end
    end
  end
end
