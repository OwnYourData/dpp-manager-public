require "httpx"
require "net/http"

module DppService
  # The wire underneath the calls to a DPP Service and to a custodian.
  #
  # EN 18216:2026 clause 4 makes HTTP/2 the minimum version for DPP data
  # exchange and rules out older ones. Net::HTTP speaks HTTP/1.1 only, so the
  # request goes out through httpx, which negotiates HTTP/2 via ALPN and still
  # answers a server that offers nothing but HTTP/1.1.
  #
  # Everything above the wire stays Net::HTTP: callers build a Net::HTTP
  # request and get a real Net::HTTPResponse back, so Net::HTTPSuccess, header
  # lookup and Soya::Http.body_as_text work as they do on any other response.
  #
  # SOyA repositories are not DPP data exchange and stay on Soya::Http.
  module Transport
    class Error < StandardError; end

    # Net::HTTP adds these on its own. httpx negotiates encoding itself and
    # decodes what it asked for; a forwarded Accept-Encoding would ask for
    # something it then hands back undecoded.
    SKIPPED_HEADERS = %w[accept-encoding user-agent host connection].freeze

    module_function

    # Raises Error with "timeout", "tls_failed" or "unreachable", the names the
    # callers already translate for the operator.
    def call(request, uri, timeout:)
      headers = {}
      request.each_header { |name, value| headers[name] = value unless SKIPPED_HEADERS.include?(name) }

      session = HTTPX.with(timeout: { connect_timeout: timeout, read_timeout: timeout,
                                      request_timeout: timeout * 2 })
      answer  = session.request(request.method, uri.to_s, headers: headers, body: request.body)
      raise Error, error_name(answer.error) if answer.is_a?(HTTPX::ErrorResponse)

      to_net_http(answer)
    end

    def error_name(error)
      case error
      when HTTPX::TimeoutError then "timeout"
      when OpenSSL::SSL::SSLError then "tls_failed"
      else "unreachable"
      end
    end

    def to_net_http(answer)
      code  = answer.status.to_s
      klass = Net::HTTPResponse::CODE_TO_OBJ.fetch(code) do
        Net::HTTPResponse::CODE_CLASS_TO_OBJ.fetch(code[0], Net::HTTPUnknownResponse)
      end

      response = klass.new(answer.version.to_s, code, Rack::Utils::HTTP_STATUS_CODES.fetch(answer.status, ""))
      answer.headers.each { |name, value| response[name] = value }
      response.instance_variable_set(:@body, answer.to_s)
      response.instance_variable_set(:@read, true)
      response
    end
  end
end
