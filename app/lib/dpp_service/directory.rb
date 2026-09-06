require "net/http"
require "uri"
require "json"

module DppService
  # What this application needs to know about a DPP Service before it can talk
  # to it: is it there, and which DID does it answer under.
  #
  # Both answers come from the service itself — /up and /.well-known/dpp-service
  # — rather than from something the operator types. The service DID is what a
  # delegation names in `sub` (milestone 5); getting it by hand from an email is
  # exactly how the wrong one ends up in a signed statement.
  #
  # Net::HTTP from the standard library, no new gems, matching how the service
  # itself talks to a custodian.
  module Directory
    class Error < StandardError; end

    TIMEOUT = ENV.fetch("DPP_SERVICE_TIMEOUT", 10).to_i

    Result = Struct.new(:reachable, :did, :audience, :message, keyword_init: true) do
      def reachable? = reachable
    end

    module_function

    def probe(base_url)
      base = normalize_base(base_url)
      return Result.new(reachable: false, message: :invalid_url) if base.nil?

      health = get_json(URI.join(base + "/", "up"))
      unless health.is_a?(Hash) && health["status"].to_s == "ok"
        return Result.new(reachable: false, message: :not_a_dpp_service)
      end

      discovery = get_json(URI.join(base + "/", ".well-known/dpp-service")) || {}

      Result.new(
        reachable: true,
        did:       discovery["did"].presence,
        # A service that does not publish an audience still expects its own base
        # URL in `aud`, which is what a client can discover on its own.
        audience:  discovery["audience"].presence || base
      )
    rescue Error => e
      Result.new(reachable: false, message: e.message.to_sym)
    end

    def normalize_base(value)
      raw = value.to_s.strip.chomp("/")
      return nil if raw.empty?

      raw = "https://#{raw}" unless raw.match?(%r{\Ahttps?://})
      uri = URI.parse(raw)
      return nil unless uri.is_a?(URI::HTTP) && uri.host.present?

      uri.to_s.chomp("/")
    rescue URI::InvalidURIError
      nil
    end

    def get_json(uri)
      response = request(uri)
      return nil unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body)
    rescue JSON::ParserError
      nil
    end

    def request(uri)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = TIMEOUT
      http.read_timeout = TIMEOUT
      http.request(Net::HTTP::Get.new(uri.request_uri, { "Accept" => "application/json" }))
    rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH, SocketError
      raise Error, "unreachable"
    rescue Net::OpenTimeout, Net::ReadTimeout, Timeout::Error
      raise Error, "timeout"
    rescue OpenSSL::SSL::SSLError
      raise Error, "tls_failed"
    end
  end
end
