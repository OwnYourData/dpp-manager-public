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
  def response(code, body)
    klass = Net::HTTPResponse::CODE_TO_OBJ.fetch(code)
    klass.new("1.1", code, "").tap do |r|
      r.instance_variable_set(:@body, body)
      r.instance_variable_set(:@read, true)
      r["content-type"] = "application/json; charset=utf-8"
    end
  end
end
