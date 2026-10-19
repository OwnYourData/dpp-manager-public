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
  # Over HTTP/2 through Transport, like every call to a DPP Service.
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

    # Whom the service takes grants for authorities from, as it publishes it
    # under /.well-known/dpp-service. Raises Error when the service does not
    # answer with a discovery document.
    def authority_issuers(base_url)
      base = normalize_base(base_url) or raise Error, "invalid_url"
      discovery = get_json(URI.join(base + "/", ".well-known/dpp-service"))
      raise Error, "no_discovery" unless discovery.is_a?(Hash)

      Array(discovery["authorityIssuers"]).map(&:to_s).reject(&:empty?)
    end

    # The reader the service has for a custodian, as it publishes it under
    # /.well-known/dpp-service: the DID the custodian enters for a collection,
    # so that the service can read the part of a passport that is not public
    # there. nil when the service names none for that custodian or cannot be
    # asked.
    def reader_for(base_url, custodian)
      base = normalize_base(base_url)
      pod  = normalize_base(custodian)&.downcase
      return nil if base.nil? || pod.nil?

      discovery = get_json(URI.join(base + "/", ".well-known/dpp-service"))
      return nil unless discovery.is_a?(Hash)

      entry = Array(discovery["readers"]).find do |reader|
        reader.is_a?(Hash) && normalize_base(reader["pod"])&.downcase == pod
      end
      entry && entry["did"].to_s.presence
    rescue Error
      nil
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
      Transport.call(Net::HTTP::Get.new(uri.request_uri, { "Accept" => "application/json" }), uri,
                     timeout: TIMEOUT)
    rescue Transport::Error => e
      raise Error, e.message
    end
  end
end
