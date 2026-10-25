require "test_helper"
require "net/http"

# What the client makes of the service's answers.
#
# The reason this class exists at all is the refusal path: the DPP Service
# answers a rejected CreateDPP with a Result object (EN 18222:2026 Table 13)
# whose message array carries the sentence explaining why. That sentence is the
# only useful thing in the response, and a client that raised on a non-2xx —
# which is right for a repository and is what Soya::Http does — would replace it
# with the number 400.
class DppServiceClientTest < ActiveSupport::TestCase
  test "an accepted passport comes back with the document the service stored" do
    stored = { "digitalProductPassportId" => "did:oyd:zQmPassport", "dppStatus" => "Active" }
    result = DppService::Client.interpret(response("201", JSON.generate(stored)))

    assert result.ok?
    assert_equal 201, result.http_status
    assert_equal stored, result.document
    assert_empty result.problems
  end

  # The DPP Service's refusal for a collection whose custodian has not entered
  # its reader, word for word as it sends it.
  READER_REFUSAL = "Refused: the custodian at https://dpp.go-data.at has no reader entered for collection 36, " \
                   "so the 2 attribute(s) of this passport that are not public could not be read there with " \
                   "access rights. Nothing was written. Please ask the custodian to enter this service's reader " \
                   "did:oyd:zQmQcGAi1ms87cXJVEAV4BHsYXbS2R86FomWktXgBpVL13z for the collection".freeze

  test "the refusal for a collection without the service's reader names custodian, collection and reader" do
    body = { "statusCode" => "ClientErrorBadRequest", "message" => [ { "messageType" => "Error", "text" => READER_REFUSAL } ] }

    missing = DppService::Client.reader_missing(DppService::Client.interpret(response("400", JSON.generate(body))))

    assert_equal "https://dpp.go-data.at", missing.custodian
    assert_equal "36", missing.collection
    assert_equal "did:oyd:zQmQcGAi1ms87cXJVEAV4BHsYXbS2R86FomWktXgBpVL13z", missing.reader_did
  end

  # The service gives the refusal the code readerNotEntered; the text still
  # carries the details.
  test "the refusal is recognised by its code, and its text gives custodian, collection and reader" do
    body = { "statusCode" => "ClientErrorBadRequest",
             "message" => [ { "messageType" => "Error", "text" => READER_REFUSAL, "code" => "readerNotEntered" } ] }

    result = DppService::Client.interpret(response("400", JSON.generate(body)))
    missing = DppService::Client.reader_missing(result, custodian: "https://elsewhere.example", collection: "99")

    assert_equal [ "readerNotEntered" ], result.codes
    assert_equal "https://dpp.go-data.at", missing.custodian
    assert_equal "36", missing.collection
    assert_equal "did:oyd:zQmQcGAi1ms87cXJVEAV4BHsYXbS2R86FomWktXgBpVL13z", missing.reader_did
  end

  test "a coded refusal in other words still counts, for the custodian and collection the write was meant for" do
    body = { "message" => [ { "messageType" => "Error", "text" => "Refused: put differently now",
                              "code" => "readerNotEntered" } ] }

    missing = DppService::Client.reader_missing(DppService::Client.interpret(response("400", JSON.generate(body))),
                                                custodian: "https://pod.example", collection: "7")

    assert_equal "https://pod.example", missing.custodian
    assert_equal "7", missing.collection
    assert_nil missing.reader_did, "the reader is left to the caller"
  end

  test "the wording alone counts only when the answer carries no code" do
    older = DppService::Client::Result.new(ok: false, http_status: 400, problems: [ READER_REFUSAL ], codes: [])
    other_code = DppService::Client::Result.new(ok: false, http_status: 400, problems: [ READER_REFUSAL ],
                                                codes: [ "somethingElse" ])

    assert_equal "36", DppService::Client.reader_missing(older).collection
    assert_nil DppService::Client.reader_missing(other_code)
  end

  test "no other answer is taken for that refusal" do
    other = DppService::Client::Result.new(ok: false, http_status: 400, problems: [ "serviceEndpoint host does not match" ])
    wrong_status = DppService::Client::Result.new(ok: false, http_status: 502, problems: [ READER_REFUSAL ],
                                                  codes: [ "readerNotEntered" ])
    accepted = DppService::Client::Result.new(ok: true, http_status: 201, problems: [])

    assert_nil DppService::Client.reader_missing(other)
    assert_nil DppService::Client.reader_missing(wrong_status)
    assert_nil DppService::Client.reader_missing(accepted)
    assert_nil DppService::Client.reader_missing(nil)
  end

  test "a refusal keeps the service's own sentence, which is the only useful part" do
    body = {
      "statusCode" => "ClientErrorBadRequest",
      "message" => [ { "messageType" => "Error",
                       "text" => "serviceEndpoint host does not match dpp-service.example" } ]
    }

    result = DppService::Client.interpret(response("400", JSON.generate(body)))

    assert_not result.ok?
    assert_equal 400, result.http_status
    assert_nil result.document
    assert_equal [ "serviceEndpoint host does not match dpp-service.example" ], result.problems
  end

  test "several messages all survive, because a refusal can have more than one reason" do
    body = { "message" => [ { "text" => "first" }, { "text" => "second" }, { "messageType" => "Info" } ] }

    assert_equal %w[first second], DppService::Client.interpret(response("400", JSON.generate(body))).problems
  end

  test "the codes of the messages are kept, where there are any" do
    body = { "message" => [ { "text" => "first", "code" => "readerNotEntered" }, { "text" => "second" },
                            { "text" => "third", "code" => "" } ] }

    assert_equal [ "readerNotEntered" ], DppService::Client.interpret(response("400", JSON.generate(body))).codes
    assert_empty DppService::Client.interpret(response("502", "<html>Bad Gateway</html>")).codes
  end

  # A proxy in front of the service answers HTML, and "unexpected token <" is
  # not a sentence to put in front of an operator.
  test "an answer that is not a Result object still says something honest" do
    result = DppService::Client.interpret(response("502", "<html>Bad Gateway</html>"))

    assert_not result.ok?
    assert_equal [ "HTTP 502" ], result.problems
  end

  test "a success with an unreadable body is still a success, without a document" do
    result = DppService::Client.interpret(response("201", "not json"))

    assert result.ok?
    assert_nil result.document
  end

  # --- the token names its request ------------------------------------------

  # Stands in for Did::Token::Bearer: records what it was asked to mint for.
  RecordingBearer = Struct.new(:asked) do
    def token_for(method, target, body)
      asked << [ method, target, body ]
      "minted-#{asked.size}"
    end
  end

  test "the token of a write is minted for exactly the method, target and body that go out" do
    sent = []
    bearer = RecordingBearer.new([])
    stubbing(DppService::Client, :perform, ->(request, uri) { sent << [ request, uri ]; response("200", "{}") }) do
      DppService::Client.update({ "facilityId" => "x" }, base_url: "https://dpp-service.example",
                                                         dpp_id: "did:oyd:zQmP", token: bearer)
      DppService::Client.delete(base_url: "https://dpp-service.example", dpp_id: "did:oyd:zQmP", token: bearer)
    end

    (patch, patch_uri), (delete, _) = sent
    assert_equal [ "PATCH", "/dpp/v1/dpps/did%3Aoyd%3AzQmP?representation=full", patch.body ], bearer.asked[0],
      "the query is part of the request-target, the body the bytes sent"
    assert_equal patch_uri.request_uri, bearer.asked[0][1]
    assert_equal "Bearer minted-1", patch["Authorization"]
    assert_equal [ "DELETE", "/dpp/v1/dpps/did%3Aoyd%3AzQmP", "" ], bearer.asked[1], "no body is the empty one"
    assert_equal "Bearer minted-2", delete["Authorization"]
  end

  test "a token handed in as a string is sent as it is" do
    sent = []
    stubbing(DppService::Client, :perform, ->(request, _uri) { sent << request; response("200", "[]") }) do
      DppService::Client.list_access_grants(base_url: "https://dpp-service.example", token: "t")
    end

    assert_equal "Bearer t", sent.first["Authorization"]
  end

  # --- the signature of the economic operator --------------------------------

  test "what is signed is read without a token, in the full representation, as the bytes that came" do
    sent = []
    body = %({"digitalProductPassportId":"did:oyd:zQmP","elements":[]})
    result = stubbing(DppService::Client, :perform, ->(request, uri) { sent << [ request, uri ]; response("200", body) }) do
      DppService::Client.read_for_signing(base_url: "https://dpp-service.example/", dpp_id: "did:oyd:zQmP")
    end

    request, uri = sent.first
    assert_equal "GET", request.method
    assert_equal "/dpp/v1/dpps/did%3Aoyd%3AzQmP?representation=full", uri.request_uri
    assert_nil request["Authorization"], "a reader without access rights gets what is signed"
    assert_equal body, result.raw
  end

  test "the signature is handed in as the body of a PUT, under a token minted for it" do
    sent = []
    bearer = RecordingBearer.new([])
    answer = response("200", JSON.generate("statusCode" => "Success",
                                           "message" => [ { "messageType" => "Info", "text" => "signature accepted" } ]),
                      "X-DPP-Signature-State" => "signed")
    result = stubbing(DppService::Client, :perform, ->(request, uri) { sent << [ request, uri ]; answer }) do
      DppService::Client.submit_signature("h.p.s", base_url: "https://dpp-service.example", dpp_id: "did:oyd:zQmP",
                                                   token: bearer)
    end

    request, uri = sent.first
    assert_equal "PUT", request.method
    assert_equal "/dpp/v1/dpps/did%3Aoyd%3AzQmP/signature", uri.request_uri
    assert_equal "application/jose", request["Content-Type"]
    assert_equal "h.p.s", request.body
    assert_equal [ "PUT", "/dpp/v1/dpps/did%3Aoyd%3AzQmP/signature", "h.p.s" ], bearer.asked.first
    assert result.ok?
    assert_equal "signed", result.signature_state
    assert_empty result.warnings, "an Info message is no warning"
  end

  test "the warning on a representative's signature is kept, and the state read from every answer" do
    warning = "signed by did:oyd:zQmRep, which is not the economicOperatorId did:oyd:zQmOp: accepted"
    result = DppService::Client.interpret(
      response("200", JSON.generate("statusCode" => "Success",
                                    "message" => [ { "messageType" => "Warning", "text" => warning } ]),
               "X-DPP-Signature-State" => "signed")
    )

    assert_equal [ warning ], result.warnings
    assert_equal "pending", DppService::Client.interpret(response("200", "{}", "X-DPP-Signature-State" => "pending"))
                                              .signature_state
    assert_nil DppService::Client.interpret(response("200", "{}")).signature_state,
      "a service that says nothing knows no signature of the economic operator"
  end

  private

  # A real Net::HTTPResponse rather than a double: body_as_text asks it for its
  # type_params, and a stand-in that answered differently would hide exactly the
  # encoding bug that made body_as_text necessary.
  # The payload commitment (EN 18246:2026) arrives in headers, because the document
  # carries the attributes of EN 18223:2026 Table 1 and nothing else. `pending`
  # is the state that asks something of this application: the service has the
  # hash but not the key to sign the entry with.
  test "the commitment comes out of the headers, not the document" do
    result = DppService::Client.interpret(
      response("200", "{}", "X-DPP-Payload-Hash" => "zQmPayload",
                            "X-DPP-Commit-State" => "pending")
    )

    assert_equal "zQmPayload", result.commitment.payload_hash
    assert result.commitment.pending?
    assert_not result.commitment.committed?
  end

  test "a committed passport says so" do
    result = DppService::Client.interpret(
      response("200", "{}", "X-DPP-Commit-State" => "committed")
    )

    assert result.commitment.committed?
  end

  # An older service, or a passport that has never been through a commitment.
  test "no headers means no commitment, not a pending one" do
    assert_nil DppService::Client.interpret(response("200", "{}")).commitment
  end

  test "the availability period travels as a header, and only when there is one" do
    sent = []
    stubbing(DppService::Client, :perform, ->(request, _uri) { sent << request; response("201", "{}") }) do
      DppService::Client.create({}, base_url: "https://dpp-service.example", token: "t",
                                    retain_until: Date.new(2037, 3, 1))
      DppService::Client.create({}, base_url: "https://dpp-service.example", token: "t")
    end

    assert_equal "2037-03-01", sent.first["X-DPP-Retain-Until"]
    assert_nil sent.last["X-DPP-Retain-Until"]
  end

  # The service answers in the compressed form unless asked for the full one
  # (EN 18222:2026 8.1); this application reads `elements`, so every call that
  # gets a passport back asks for the full form.
  test "every call that returns a passport asks for the full representation" do
    sent = []
    stubbing(DppService::Client, :perform, ->(_request, uri) { sent << uri; response("200", "{}") }) do
      base = "https://dpp-service.example"
      DppService::Client.create({}, base_url: base, token: "t")
      DppService::Client.update({}, base_url: base, dpp_id: "did:oyd:zQmP", token: "t")
      DppService::Client.read_by_product_id(base_url: base, product_id: "https://dpp.example/01/09520123456788")
      DppService::Client.read("https://dpp.go-data.at/dpp/v1/dppsByProductId/x")
      DppService::Client.move_custody(base_url: base, dpp_id: "did:oyd:zQmP", token: "t",
                                      storage: { base_url: "https://pod.example", collection_id: "1", delegation: "j" },
                                      release_previous: true)
    end

    sent.each { |uri| assert_includes URI.decode_www_form(uri.query.to_s), %w[representation full], uri.to_s }
    assert_includes URI.decode_www_form(sent.last.query), %w[release_previous true]
    assert_equal "/dpp/v1/dpps/did%3Aoyd%3AzQmP", sent[1].path
  end

  test "an address that names a representation already gets the full one, once" do
    uri = DppService::Client.full_form(URI.parse("https://dpp-service.example/dpp/v1/dpps/x?representation=compressed&a=1"))

    assert_equal [ %w[a 1], %w[representation full] ], URI.decode_www_form(uri.query)
  end

  # --- access policies ---------------------------------------------------------

  test "the fit of the access policy comes out of the answer header" do
    result = DppService::Client.interpret(
      response("201", "{}", "X-DPP-Access-Policy" => '"did:oyd:zQmOp/access-policies/DppLedLamp/2";unclassified=1;unused-rules=3')
    )

    assert_equal "did:oyd:zQmOp/access-policies/DppLedLamp/2", result.access_policy.id
    assert_equal 1, result.access_policy.unclassified
    assert_equal 3, result.access_policy.unused_rules
  end

  test "an escaped quote in the policy id survives the header" do
    report = DppService::Client.parse_access_policy_header('"https://x.example/a\\"b";unclassified=0;unused-rules=0')

    assert_equal 'https://x.example/a"b', report.id
  end

  # A passport without a policy, a read, an older service.
  test "no header means no report, and a header of another shape is not guessed at" do
    assert_nil DppService::Client.interpret(response("200", "{}")).access_policy
    assert_nil DppService::Client.parse_access_policy_header("unclassified=1")
  end

  test "the access policy travels by its id, on create and update, and only when there is one" do
    sent = []
    stubbing(DppService::Client, :perform, ->(request, _uri) { sent << request; response("201", "{}") }) do
      base = "https://dpp-service.example"
      DppService::Client.create({}, base_url: base, token: "t", access_policy: "did:oyd:zQmOp/access-policies/T/1")
      DppService::Client.create({}, base_url: base, token: "t")
      DppService::Client.update({}, base_url: base, dpp_id: "did:oyd:zQmP", token: "t",
                                    access_policy: "did:oyd:zQmOp/access-policies/T/2")
      DppService::Client.update({}, base_url: base, dpp_id: "did:oyd:zQmP", token: "t")
    end

    assert_equal "did:oyd:zQmOp/access-policies/T/1", sent[0]["X-DPP-Access-Policy"]
    assert_nil sent[1]["X-DPP-Access-Policy"]
    assert_equal "did:oyd:zQmOp/access-policies/T/2", sent[2]["X-DPP-Access-Policy"]
    assert_equal "{}", sent[2].body, "applying a policy changes nothing of the document"
    assert_nil sent[3]["X-DPP-Access-Policy"]
  end

  test "a policy is registered with a PUT of the document, under the operator's token" do
    sent = []
    policy = { "id" => "did:oyd:zQmOp/access-policies/T/1", "scheme" => Dpp::AccessPolicy::SCHEME, "rules" => [] }
    result = stubbing(DppService::Client, :perform, ->(request, uri) { sent << [ request, uri ]; response("201", JSON.generate(policy)) }) do
      DppService::Client.register_access_policy(policy, base_url: "https://dpp-service.example/", token: "t")
    end

    request, uri = sent.first
    assert_equal "PUT", request.method
    assert_equal "/dpp/v1/access-policies", uri.path
    assert_equal "application/json", request["Content-Type"]
    assert_equal "Bearer t", request["Authorization"]
    assert_equal policy, JSON.parse(request.body)
    assert result.ok?
  end

  test "the lists behind the counts are read for one passport" do
    sent = []
    body = { "policy" => "p", "unclassified" => [ "A/B" ], "unusedRules" => [] }
    result = stubbing(DppService::Client, :perform, ->(request, uri) { sent << [ request, uri ]; response("200", JSON.generate(body)) }) do
      DppService::Client.read_access_policy(base_url: "https://dpp-service.example", dpp_id: "did:oyd:zQmP", token: "t")
    end

    request, uri = sent.first
    assert_equal "GET", request.method
    assert_equal "/dpp/v1/dpps/did%3Aoyd%3AzQmP/access-policy", uri.path
    assert_equal body, result.document
  end

  # --- access grants -----------------------------------------------------------

  test "an access grant is registered as it was signed, under the issuer's token" do
    sent = []
    result = stubbing(DppService::Client, :perform, ->(request, uri) { sent << [ request, uri ]; response("201", '{"jti":"grant-1"}') }) do
      DppService::Client.register_access_grant("header.claims.signature", base_url: "https://dpp-service.example/", token: "t")
    end

    request, uri = sent.first
    assert_equal "PUT", request.method
    assert_equal "/dpp/v1/access-grants", uri.path
    assert_equal "application/jwt", request["Content-Type"]
    assert_equal "Bearer t", request["Authorization"]
    assert_equal "header.claims.signature", request.body
    assert_equal({ "jti" => "grant-1" }, result.document)
  end

  test "a refused grant keeps the service's sentence" do
    body = { "message" => [ { "text" => "did:oyd:zQmX is not on the list of issuers" } ] }
    result = stubbing(DppService::Client, :perform, ->(*) { response("403", JSON.generate(body)) }) do
      DppService::Client.register_access_grant("g", base_url: "https://dpp-service.example", token: "t")
    end

    assert_not result.ok?
    assert_equal 403, result.http_status
    assert_equal [ "did:oyd:zQmX is not on the list of issuers" ], result.problems
  end

  test "the grants of an issuer come back as a list" do
    grants = [ { "jti" => "grant-1", "revoked" => false } ]
    sent = []
    result = stubbing(DppService::Client, :perform, ->(request, uri) { sent << [ request, uri ]; response("200", JSON.generate(grants)) }) do
      DppService::Client.list_access_grants(base_url: "https://dpp-service.example", token: "t")
    end

    assert_equal "GET", sent.first[0].method
    assert_equal "/dpp/v1/access-grants", sent.first[1].path
    assert_equal grants, result.list
    assert_nil result.document
  end

  test "a grant is revoked by its jti, escaped as one path segment" do
    sent = []
    stubbing(DppService::Client, :perform, ->(request, uri) { sent << [ request, uri ]; response("200", "{}") }) do
      DppService::Client.revoke_access_grant("grant-1/x", base_url: "https://dpp-service.example", token: "t")
    end

    assert_equal "DELETE", sent.first[0].method
    assert_equal "/dpp/v1/access-grants/grant-1%2Fx", sent.first[1].path
  end

  def response(code, body, headers = {})
    klass = Net::HTTPResponse::CODE_TO_OBJ.fetch(code)
    klass.new("1.1", code, "").tap do |r|
      r.instance_variable_set(:@body, body)
      r.instance_variable_set(:@read, true)
      r["content-type"] = "application/json; charset=utf-8"
      headers.each { |name, value| r[name] = value }
    end
  end
end
