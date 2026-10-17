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

  private

  # A real Net::HTTPResponse rather than a double: body_as_text asks it for its
  # type_params, and a stand-in that answered differently would hide exactly the
  # encoding bug that made body_as_text necessary.
  # The payload commitment (prEN 18246) arrives in headers, because the document
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
