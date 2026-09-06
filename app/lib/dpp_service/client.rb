require "net/http"
require "uri"
require "json"
require "cgi"

module DppService
  # Talking to the DPP Service as an economic operator.
  #
  # Its own request handling rather than Soya::Http, for one reason that matters:
  # this service answers a refusal with a Result object (EN 18222:2026 Table 13)
  # whose `message` array carries the sentence the operator needs. Raising on a
  # non-2xx, which is what Soya::Http does and is right for a repository, would
  # throw that sentence away and leave "http_400" in its place.
  module Client
    class Error < StandardError; end

    TIMEOUT = ENV.fetch("DPP_SERVICE_TIMEOUT", 30).to_i

    # ok?      the service accepted it
    # document what it stored, as it returned it
    # problems the sentences from the Result object, ready to show
    Result = Struct.new(:ok, :http_status, :document, :problems, keyword_init: true) do
      def ok? = ok
    end

    module_function

    # CreateDPP — POST /dpp/v1/dpps.
    #
    # The passport's DID travels inside the document as
    # `digitalProductPassportId`; that is what tells the service this is
    # variant B and stops it minting one of its own. There is no proprietary
    # field for it and no header: the presence of the attribute is the signal.
    # `storage` is the custody header of docs/Delegation.md §9: where the
    # passport is to be kept and the signed mandate that allows the service to
    # keep it there. Absent, the service stores the passport in its own
    # database; present, it stores it at the custodian named in it and the
    # passport's DID has to point there.
    #
    # A header and not a field of the document, and that is the service's
    # decision rather than ours: EN 18223 says what a passport contains, and
    # where it is kept is not part of it.
    def create(document, base_url:, token:, storage: nil)
      uri = URI.parse("#{base_url.to_s.chomp('/')}/dpp/v1/dpps")

      request = Net::HTTP::Post.new(uri.request_uri,
        "Content-Type"  => "application/json",
        "Accept"        => "application/json",
        "Authorization" => "Bearer #{token}")
      request["X-DPP-Storage"] = storage_header(storage) if storage.present?
      request.body = JSON.generate(document)

      interpret(perform(request, uri))
    end

    # What the service holds as the mandate for this passport: jti, exp, act,
    # collection and base_url, read from the stored assertion without being
    # verified — an expired mandate is exactly what a caller is here to find
    # out about.
    #
    # It exists because the operator keeps their own record of what they
    # signed, and after a restore from an older backup the two drift apart. The
    # drift is otherwise silent, with the operator counting a passport as
    # provided for while the service sits on a mandate that no longer works.
    def read_delegation(base_url:, dpp_id:, token:)
      uri = URI.parse("#{base_url.to_s.chomp('/')}/dpp/v1/dpps/#{CGI.escape(dpp_id.to_s)}/delegation")

      request = Net::HTTP::Get.new(uri.request_uri,
        "Accept"        => "application/json",
        "Authorization" => "Bearer #{token}")

      interpret(perform(request, uri))
    end

    # A fresh mandate for a passport the service already holds at a custodian.
    #
    # An operation of its own rather than a header on the correction: a merge
    # patch is about the document, and replacing a mandate is about custody.
    # Answers 204 and nothing else — everything the answer could carry was
    # signed here moments earlier.
    def renew_delegation(base_url:, dpp_id:, token:, storage:)
      uri = URI.parse("#{base_url.to_s.chomp('/')}/dpp/v1/dpps/#{CGI.escape(dpp_id.to_s)}/delegation")

      request = Net::HTTP::Post.new(uri.request_uri,
        "Accept"        => "application/json",
        "Authorization" => "Bearer #{token}")
      request["X-DPP-Storage"] = storage_header(storage)

      interpret(perform(request, uri))
    end

    # Handing the passport to a different custodian.
    #
    # The mandate in the header is for the new one, and the service redeems it
    # before it moves anything: a custodian that cannot be written to must not
    # end up named on a passport that never arrived there.
    #
    # `release_previous` is off by default here, and that is the whole ordering
    # argument of a handover. The previous custodian goes on serving until it is
    # released, so between the move and the moment this application points the
    # identifier at the new host there is no instant in which the passport
    # cannot be read. Releasing at once trades that continuity for a clean exit,
    # which is the operator's call and not this application's.
    def move_custody(base_url:, dpp_id:, token:, storage:, release_previous: false)
      path = "#{base_url.to_s.chomp('/')}/dpp/v1/dpps/#{CGI.escape(dpp_id.to_s)}/custody"
      path += "?release_previous=true" if release_previous
      uri = URI.parse(path)

      request = Net::HTTP::Post.new(uri.request_uri,
        "Accept"        => "application/json",
        "Authorization" => "Bearer #{token}")
      request["X-DPP-Storage"] = storage_header(storage)

      interpret(perform(request, uri))
    end

    def storage_header(storage)
      JSON.generate(
        "base_url"      => storage[:base_url].to_s.chomp("/"),
        "collection_id" => storage[:collection_id].to_s,
        "delegation"    => storage[:delegation].to_s
      )
    end

    # UpdateDPP — PATCH /dpp/v1/dpps/:dpp_id, RFC 7396.
    #
    # A merge patch, not a replacement: what is not in the patch is left alone,
    # which is what keeps this application from having an opinion about the
    # attributes the service owns — dppStatus, lastUpdated, the owner. An array
    # in a merge patch replaces rather than merges, so sending `elements` sends
    # the whole element tree, which is the only sensible reading of a corrected
    # passport.
    #
    # The identifier goes in the path percent-encoded as one segment: it is a
    # DID and contains colons, and the service widened its route constraint for
    # exactly that.
    def update(patch, base_url:, dpp_id:, token:)
      uri = URI.parse("#{base_url.to_s.chomp('/')}/dpp/v1/dpps/#{CGI.escape(dpp_id.to_s)}")

      request = Net::HTTP::Patch.new(uri.request_uri,
        "Content-Type"  => "application/json",
        "Accept"        => "application/json",
        "Authorization" => "Bearer #{token}")
      request.body = JSON.generate(patch)

      interpret(perform(request, uri))
    end

    # DeleteDPPById — DELETE /dpp/v1/dpps/:dpp_id.
    #
    # The service archives the final state and stops serving the passport; the
    # history stays retrievable by date. It does not revoke the identifier of a
    # passport it did not mint, and it holds no key for one — that half is ours.
    def delete(base_url:, dpp_id:, token:)
      uri = URI.parse("#{base_url.to_s.chomp('/')}/dpp/v1/dpps/#{CGI.escape(dpp_id.to_s)}")

      request = Net::HTTP::Delete.new(uri.request_uri,
        "Accept"        => "application/json",
        "Authorization" => "Bearer #{token}")

      interpret(perform(request, uri))
    end

    # ReadDPPByProductId — GET /dpp/v1/dppsByProductId/:product_id.
    #
    # No token. Reading a passport is what the standard means by a passport:
    # anyone holding the product can hold its identifier, and the whole point is
    # that they can then read it. This application signs what it writes and
    # signs nothing to read.
    #
    # The service answers with the active version only; a passport that was
    # ended is 404 here, and its history is reached by date instead.
    def read_by_product_id(base_url:, product_id:)
      read("#{base_url.to_s.chomp('/')}/dpp/v1/dppsByProductId/#{CGI.escape(product_id.to_s)}")
    end

    # The same read against an address that was worked out elsewhere — a
    # passport DID's serviceEndpoint, which points at whichever service or
    # custodian actually serves it. The address comes out of a signed DID
    # document, so it is the passport's own statement about where it lives.
    def read(url)
      uri = URI.parse(url.to_s)
      raise Error, "invalid_address" unless uri.is_a?(URI::HTTP) && uri.host.present?

      interpret(perform(Net::HTTP::Get.new(uri.request_uri, "Accept" => "application/json"), uri))
    rescue URI::InvalidURIError
      raise Error, "invalid_address"
    end

    def perform(request, uri)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = TIMEOUT
      http.read_timeout = TIMEOUT
      http.request(request)
    rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH, SocketError
      raise Error, "unreachable"
    rescue Net::OpenTimeout, Net::ReadTimeout, Timeout::Error
      raise Error, "timeout"
    rescue OpenSSL::SSL::SSLError
      raise Error, "tls_failed"
    end

    def interpret(response)
      body = parse(response)
      ok   = response.is_a?(Net::HTTPSuccess)

      Result.new(ok: ok, http_status: response.code.to_i,
                 document: (body if ok && body.is_a?(Hash)),
                 problems: (ok ? [] : problems_in(body, response)))
    end

    # The Result object's messages, or something honest when the answer was not
    # one — a proxy in front of the service answers HTML, and "unexpected token
    # <" is not a sentence to put in front of an operator.
    def problems_in(body, response)
      messages = Array(body.is_a?(Hash) ? body["message"] : nil)
                 .filter_map { |entry| entry["text"].presence if entry.is_a?(Hash) }
      return messages if messages.any?

      [ "HTTP #{response.code}" ]
    end

    def parse(response)
      JSON.parse(Soya::Http.body_as_text(response))
    rescue JSON::ParserError
      nil
    end
  end
end
