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
    # codes    the codes of its messages, where the service gives one; a refusal
    #          is recognised by these rather than by the wording of a sentence
    #
    # list     what the service stored or returned when that is an array rather
    #          than one document (the access grants of an issuer)
    #
    # signature_state  what the service says about the signature of the
    #          economic operator on this passport (X-DPP-Signature-State: none,
    #          pending, signed, stale); nil from a service that knows none
    # warnings the sentences of an accepted request's messages of type Warning
    # raw      the body as it arrived, for the one caller that signs it
    Result = Struct.new(:ok, :http_status, :document, :problems, :codes, :commitment, :access_policy, :list,
                        :signature_state, :warnings, :raw, keyword_init: true) do
      def ok? = ok
    end

    SIGNATURE_STATE_HEADER = "X-DPP-Signature-State".freeze

    # What the service says after a write about the access policy the passport
    # is classified by (docs/AccessClasses.md of the DPP Service): which policy,
    # how many attributes no rule reaches, how many rules reach nothing. Counts
    # only; the lists are read with read_access_policy.
    AccessPolicyReport = Struct.new(:id, :unclassified, :unused_rules, keyword_init: true) do
      def to_h = { "policy" => id, "unclassified" => unclassified, "unusedRules" => unused_rules }
    end

    ACCESS_POLICY_HEADER = "X-DPP-Access-Policy".freeze

    # The one refusal only the custodian can resolve: the passport has
    # attributes that are not public, and the custodian has not entered the
    # service's reader for the collection they would be written to, so nobody
    # entitled could read them there. The service says so with 400 and the code
    # readerNotEntered, and names custodian, collection and reader in the text;
    # this is what the operator passes on.
    ReaderMissing = Struct.new(:custodian, :collection, :reader_did, keyword_init: true)

    READER_NOT_ENTERED = "readerNotEntered".freeze

    # The wording of that text. It gives the details, and it is how the refusal
    # is recognised from a service that does not give the code yet.
    READER_MISSING = /the custodian at (\S+) has no reader entered for collection (\S+?),.*this service's reader (did:\S+) for the collection/m

    # What the service says about the payload commitment (EN 18246:2026). It
    # arrives in headers and not in the document, because the payload carries
    # the attributes of EN 18223:2026 Table 1 and nothing else.
    #
    # `pending?` is the state that asks something of this application: the service
    # has computed the hash but cannot sign the log entry, because the document
    # key is here and not there.
    Commitment = Struct.new(:payload_hash, :state, keyword_init: true) do
      def pending? = state == "pending"
      def committed? = state == "committed"
      def stale? = state == "stale"
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
    #
    # `retain_until` is the last day the passport has to stay available (ESPR
    # Art. 9(2)(i)). A header for the same reason as the custody: it is about
    # how the service keeps the passport, not about what the passport says.
    #
    # `access_policy` is the id of an access policy registered beforehand with
    # register_access_policy. Absent, the passport has none and is public as a
    # whole, as before.
    def create(document, base_url:, token:, storage: nil, retain_until: nil, access_policy: nil)
      uri = full_form(URI.parse("#{base_url.to_s.chomp('/')}/dpp/v1/dpps"))

      request = Net::HTTP::Post.new(uri.request_uri,
        "Content-Type"  => "application/json",
        "Accept"        => "application/json")
      request["X-DPP-Storage"] = storage_header(storage) if storage.present?
      request["X-DPP-Retain-Until"] = retain_until.iso8601 if retain_until.present?
      request[ACCESS_POLICY_HEADER] = access_policy if access_policy.present?
      request.body = JSON.generate(document)

      authorize!(request, uri, token)
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
        "Accept"        => "application/json")

      authorize!(request, uri, token)
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
        "Accept"        => "application/json")
      request["X-DPP-Storage"] = storage_header(storage)

      authorize!(request, uri, token)
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
      uri = full_form(URI.parse(path))

      request = Net::HTTP::Post.new(uri.request_uri,
        "Accept"        => "application/json")
      request["X-DPP-Storage"] = storage_header(storage)

      authorize!(request, uri, token)
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
    #
    # With `access_policy` the passport is classified by that policy from now
    # on, in place of the one it had. A passport keeps a policy once it has
    # one; the service has no way to take it off.
    def update(patch, base_url:, dpp_id:, token:, access_policy: nil)
      uri = full_form(URI.parse("#{base_url.to_s.chomp('/')}/dpp/v1/dpps/#{CGI.escape(dpp_id.to_s)}"))

      request = Net::HTTP::Patch.new(uri.request_uri,
        "Content-Type"  => "application/json",
        "Accept"        => "application/json")
      request[ACCESS_POLICY_HEADER] = access_policy if access_policy.present?
      request.body = JSON.generate(patch)

      authorize!(request, uri, token)
      interpret(perform(request, uri))
    end

    # Registering an access policy — PUT /dpp/v1/access-policies.
    #
    # 201 registered, 200 the same policy was there already; both are success.
    # 409 says a different policy is registered under this id, which the caller
    # answers with the next version. A registered policy never changes.
    def register_access_policy(policy, base_url:, token:)
      uri = URI.parse("#{base_url.to_s.chomp('/')}/dpp/v1/access-policies")

      request = Net::HTTP::Put.new(uri.request_uri,
        "Content-Type"  => "application/json",
        "Accept"        => "application/json")
      request.body = JSON.generate(policy)

      authorize!(request, uri, token)
      interpret(perform(request, uri))
    end

    # Which attributes of a passport its policy leaves to the default and which
    # rules reach nothing — GET /dpp/v1/dpps/:dpp_id/access-policy, owner only.
    def read_access_policy(base_url:, dpp_id:, token:)
      uri = URI.parse("#{base_url.to_s.chomp('/')}/dpp/v1/dpps/#{CGI.escape(dpp_id.to_s)}/access-policy")

      request = Net::HTTP::Get.new(uri.request_uri,
        "Accept"        => "application/json")

      authorize!(request, uri, token)
      interpret(perform(request, uri))
    end

    # Registering an access grant — PUT /dpp/v1/access-grants.
    #
    # The body is the signed grant as it is (application/jwt); the bearer token
    # is the issuer's. 201 registered, 200 registered before. 400 not a valid
    # grant, 403 the issuer may not grant this, 409 a different grant under the
    # same jti — each with the service's own sentence.
    def register_access_grant(grant, base_url:, token:)
      uri = URI.parse("#{base_url.to_s.chomp('/')}/dpp/v1/access-grants")

      request = Net::HTTP::Put.new(uri.request_uri,
        "Content-Type"  => "application/jwt",
        "Accept"        => "application/json")
      request.body = grant.to_s

      authorize!(request, uri, token)
      interpret(perform(request, uri))
    end

    # The grants the presenting DID has issued, with their claims and whether
    # they are revoked, but not the signed statements — GET
    # /dpp/v1/access-grants. They come back in `list`.
    def list_access_grants(base_url:, token:)
      uri = URI.parse("#{base_url.to_s.chomp('/')}/dpp/v1/access-grants")

      request = Net::HTTP::Get.new(uri.request_uri,
        "Accept"        => "application/json")

      authorize!(request, uri, token)
      interpret(perform(request, uri))
    end

    # Revoking an access grant, with effect from now — DELETE
    # /dpp/v1/access-grants/:jti. 200 revoked (now or before; the answer says
    # when and by whom), 404 the presenting DID issued no grant under this jti.
    def revoke_access_grant(jti, base_url:, token:)
      uri = URI.parse("#{base_url.to_s.chomp('/')}/dpp/v1/access-grants/#{CGI.escape(jti.to_s)}")

      request = Net::HTTP::Delete.new(uri.request_uri,
        "Accept"        => "application/json")

      authorize!(request, uri, token)
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
        "Accept"        => "application/json")

      authorize!(request, uri, token)
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

    # The passport as a reader without access rights receives it, in the full
    # representation, from the service that holds it: GET
    # /dpp/v1/dpps/:dpp_id?representation=full, without a token. That is
    # exactly what the signature of the economic operator has to cover
    # (dpp-service docs/Integrity.md section 10), so the bytes come back in
    # `raw` as they arrived, to be signed unchanged.
    def read_for_signing(base_url:, dpp_id:)
      read("#{base_url.to_s.chomp('/')}/dpp/v1/dpps/#{CGI.escape(dpp_id.to_s)}")
    end

    # Handing in the signature of the economic operator — PUT
    # /dpp/v1/dpps/:dpp_id/signature, the JWS in the compact serialization as
    # the body. 200 accepted, with X-DPP-Signature-State: signed and, where the
    # signer is not the economicOperatorId of the passport, a message of type
    # Warning; 400 among other things when the passport changed since it was
    # read.
    def submit_signature(compact, base_url:, dpp_id:, token:)
      uri = URI.parse("#{base_url.to_s.chomp('/')}/dpp/v1/dpps/#{CGI.escape(dpp_id.to_s)}/signature")

      request = Net::HTTP::Put.new(uri.request_uri,
        "Content-Type" => "application/jose",
        "Accept"       => "application/json")
      request.body = compact.to_s

      authorize!(request, uri, token)
      interpret(perform(request, uri))
    end

    # The same read against an address that was worked out elsewhere — a
    # passport DID's serviceEndpoint, which points at whichever service or
    # custodian actually serves it. The address comes out of a signed DID
    # document, so it is the passport's own statement about where it lives.
    def read(url)
      uri = URI.parse(url.to_s)
      raise Error, "invalid_address" unless uri.is_a?(URI::HTTP) && uri.host.present?

      uri = full_form(uri)

      interpret(perform(Net::HTTP::Get.new(uri.request_uri, "Accept" => "application/json"), uri))
    rescue URI::InvalidURIError
      raise Error, "invalid_address"
    end

    # Every answer that carries a passport is asked for in the full form of
    # EN 18223:2026 Annex A. The service answers in the compressed form unless
    # told otherwise (EN 18222:2026 8.1), and this application reads the
    # element tree in `elements`: the lookup shows it, and the copy kept after
    # a submission is compared against it. A custodian that knows no such flag
    # ignores it and answers with the full form it holds anyway.
    def full_form(uri)
      query = URI.decode_www_form(uri.query.to_s).reject { |key, _| key == "representation" }
      uri = uri.dup
      uri.query = URI.encode_www_form(query + [ [ "representation", "full" ] ])
      uri
    end

    # The custodian, collection and reader a refusal names, or nil when the
    # result is not that refusal.
    # The refusal for a collection without the service's reader, or nil.
    #
    # Recognised by its code. By the wording of its text only when the answer
    # carries no code at all, as from a service before the code. Custodian,
    # collection and reader come from the text where it has the known wording;
    # otherwise custodian and collection are where the write was to go
    # (+custodian+, +collection+), and the reader is left to the caller.
    def reader_missing(result, custodian: nil, collection: nil)
      return nil if result.nil? || result.ok? || result.http_status != 400

      codes = Array(result.codes)
      named = Array(result.problems).lazy.filter_map { |text| text.to_s.match(READER_MISSING) }.first
      return nil unless codes.include?(READER_NOT_ENTERED) || (codes.empty? && named)
      return ReaderMissing.new(custodian: named[1], collection: named[2], reader_did: named[3]) if named

      ReaderMissing.new(custodian: custodian, collection: collection, reader_did: nil)
    end

    # Over HTTP/2, see Transport.
    def perform(request, uri)
      Transport.call(request, uri, timeout: TIMEOUT)
    rescue Transport::Error => e
      raise Error, e.message
    end

    # The bearer token goes on last, once method, target and body are what goes
    # out: a Did::Token::Bearer mints it for exactly this request (the claim
    # rqh), and a token minted for anything else would be refused. A plain
    # string is taken as it is.
    def authorize!(request, uri, token)
      value = token.respond_to?(:token_for) ? token.token_for(request.method, uri.request_uri, request.body.to_s) : token
      request["Authorization"] = "Bearer #{value}"
    end

    def interpret(response)
      body = parse(response)
      ok   = response.is_a?(Net::HTTPSuccess)

      Result.new(ok: ok, http_status: response.code.to_i,
                 document: (body if ok && body.is_a?(Hash)),
                 list: (body if ok && body.is_a?(Array)),
                 problems: (ok ? [] : problems_in(body, response)),
                 codes: (ok ? [] : codes_in(body)),
                 commitment: commitment_in(response),
                 access_policy: access_policy_in(response),
                 signature_state: response[SIGNATURE_STATE_HEADER].to_s.strip.presence,
                 warnings: (ok ? warnings_in(body) : []),
                 raw: response.body.to_s)
    end

    # The Warning messages of an accepted request: the DPP Service accepts a
    # signature by someone other than the passport's economicOperatorId, as
    # that of an authorised representative, and says so this way.
    def warnings_in(body)
      Array(body.is_a?(Hash) ? body["message"] : nil)
        .filter_map { |entry| entry["text"].presence if entry.is_a?(Hash) && entry["messageType"] == "Warning" }
    end

    # The answer header, an RFC 8941 item: a string with two integer parameters.
    #
    #   "did:oyd:z…/access-policies/DppLedLamp/2";unclassified=1;unused-rules=3
    #
    # nil without the header — a passport without a policy, a read, an older
    # service — and for one that is not an item of that shape.
    def access_policy_in(response)
      parse_access_policy_header(response[ACCESS_POLICY_HEADER].to_s)
    end

    def parse_access_policy_header(raw)
      match = raw.strip.match(/\A"((?:[^"\\]|\\.)*)"(.*)\z/)
      return nil if match.nil?

      params = match[2].split(";").map(&:strip).reject(&:empty?).to_h do |pair|
        key, value = pair.split("=", 2)
        [ key, value.to_s.match?(/\A-?\d+\z/) ? value.to_i : value ]
      end

      AccessPolicyReport.new(id: match[1].gsub(/\\(.)/, '\\1'),
                             unclassified: params["unclassified"], unused_rules: params["unused-rules"])
    end

    # nil when the service said nothing about a commitment — which is what a
    # passport that has never been through one looks like, and what an older
    # service looks like too.
    def commitment_in(response)
      hash  = response["x-dpp-payload-hash"].presence
      state = response["x-dpp-commit-state"].presence
      return nil if hash.nil? && state.nil?

      Commitment.new(payload_hash: hash, state: state)
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

    def codes_in(body)
      Array(body.is_a?(Hash) ? body["message"] : nil)
        .filter_map { |entry| entry["code"].to_s.presence if entry.is_a?(Hash) }
    end

    def parse(response)
      JSON.parse(Soya::Http.body_as_text(response))
    rescue JSON::ParserError
      nil
    end
  end
end
