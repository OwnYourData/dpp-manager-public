require "net/http"
require "uri"
require "json"

module Soya
  # The little that both SOyA clients need: a request with timeouts, and errors
  # named after what went wrong rather than which exception class the standard
  # library happened to raise.
  #
  # Deliberately Net::HTTP and nothing else. This application ships one runtime
  # dependency it cannot avoid (the oydid gem, which is why it is Ruby at all);
  # a second HTTP library to fetch three URLs would be a poor trade.
  module Http
    module_function

    def get(uri, accept: "application/json", timeout: 15)
      run(Net::HTTP::Get.new(uri.request_uri, { "Accept" => accept }), uri, timeout)
    end

    def post_json(uri, body, timeout: 60)
      request = Net::HTTP::Post.new(uri.request_uri, { "Content-Type" => "application/json", "Accept" => "application/json" })
      request.body = body.is_a?(String) ? body : JSON.generate(body)
      run(request, uri, timeout)
    end

    def get_json(uri, timeout: 15)
      parse(get(uri, timeout: timeout))
    end

    # Net::HTTP hands back a body tagged ASCII-8BIT no matter what the response
    # said it was. That is fine right up to the first non-ASCII byte: a German
    # label in a structure's YAML then raises Encoding::UndefinedConversionError
    # somewhere far away — while saving, or while rendering — and the message
    # names a byte rather than the file it came from.
    #
    # The charset from the header is used when there is one, UTF-8 assumed when
    # there is not, and anything that still does not decode has its bad bytes
    # replaced rather than taking the import down: a structure with one damaged
    # character is worth having.
    def body_as_text(response)
      charset = response.type_params["charset"].presence || "UTF-8"
      body = response.body.to_s.dup.force_encoding(charset)
      body.valid_encoding? ? body.encode("UTF-8") : body.encode("UTF-8", invalid: :replace, undef: :replace)
    rescue ArgumentError, Encoding::ConverterNotFoundError
      response.body.to_s.dup.force_encoding("UTF-8").scrub
    end

    def parse(response)
      JSON.parse(body_as_text(response))
    rescue JSON::ParserError
      raise Error, "not_json"
    end

    def run(request, uri, timeout)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = timeout
      http.read_timeout = timeout

      response = http.request(request)
      return response if response.is_a?(Net::HTTPSuccess)

      # The body carries the reason often enough to be worth showing: web-cli
      # answers a broken structure with the parser's own message, and that is
      # the sentence the operator needs, not "500".
      raise Error, "http_#{response.code}: #{response.body.to_s.truncate(300)}"
    rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH, SocketError
      raise Error, "unreachable"
    rescue Net::OpenTimeout, Net::ReadTimeout, Timeout::Error
      raise Error, "timeout"
    rescue OpenSSL::SSL::SSLError
      raise Error, "tls_failed"
    end
  end
end
