require "test_helper"
require "net/http"

# EN 18216:2026 clause 4: HTTP/2 is the minimum for DPP data exchange. The
# calls to a DPP Service go out through httpx; what comes back has to be the
# Net::HTTPResponse the rest of the client already reads.
class DppServiceTransportTest < ActiveSupport::TestCase
  Answer = Struct.new(:status, :version, :headers, :body, keyword_init: true) do
    def to_s = body
  end

  # Stands in for an httpx session and remembers what it was asked.
  class FakeSession
    attr_reader :calls

    def initialize(answer) = (@answer = answer; @calls = [])

    def request(verb, url, headers:, body:)
      @calls << { verb: verb, url: url, headers: headers, body: body }
      @answer
    end
  end

  def with_session(answer)
    session = FakeSession.new(answer)
    stubbing(HTTPX, :with, ->(**) { session }) { yield session }
  end

  def ok_answer(status: 200, body: "{}", headers: { "content-type" => "application/json; charset=utf-8" })
    Answer.new(status: status, version: "2.0", headers: headers, body: body)
  end

  def uri = URI("https://dpp-service.example/dpp/v1/dpps")

  test "sends method, URL, the caller's headers and body, and none of Net::HTTP's own" do
    request = Net::HTTP::Post.new(uri.request_uri, "Content-Type" => "application/json", "DPoP" => "proof")
    request.body = "{\"a\":1}"

    with_session(ok_answer(status: 201)) do |session|
      DppService::Transport.call(request, uri, timeout: 5)
      call = session.calls.first

      assert_equal "POST", call[:verb]
      assert_equal "https://dpp-service.example/dpp/v1/dpps", call[:url]
      assert_equal "proof", call[:headers]["dpop"]
      assert_equal "{\"a\":1}", call[:body]
      assert_empty call[:headers].keys & %w[accept-encoding user-agent host connection]
    end
  end

  test "hands back a real Net::HTTPResponse with status, headers, body and HTTP version" do
    answer = ok_answer(headers: { "content-type" => "application/json; charset=utf-8",
                                  "x-dpp-commit-state" => "committed" }, body: "{\"x\":1}")

    with_session(answer) do
      response = DppService::Transport.call(Net::HTTP::Get.new(uri.request_uri), uri, timeout: 5)

      assert_kind_of Net::HTTPSuccess, response
      assert_equal "200", response.code
      assert_equal "2.0", response.http_version
      assert_equal "committed", response["X-DPP-Commit-State"]
      assert_equal "{\"x\":1}", response.body
      assert_equal "utf-8", response.type_params["charset"]
    end
  end

  test "maps a refusal and an unusual status onto the matching response classes" do
    with_session(ok_answer(status: 404)) do
      assert_kind_of Net::HTTPNotFound, DppService::Transport.call(Net::HTTP::Get.new("/"), uri, timeout: 5)
    end
    with_session(ok_answer(status: 299)) do
      assert_kind_of Net::HTTPSuccess, DppService::Transport.call(Net::HTTP::Get.new("/"), uri, timeout: 5)
    end
  end

  test "names failures the way the callers translate them" do
    failures = {
      HTTPX::ConnectTimeoutError.new(5, "connect timed out") => "timeout",
      OpenSSL::SSL::SSLError.new("certificate verify failed") => "tls_failed",
      HTTPX::ResolveError.new("Can't resolve dpp-service.example") => "unreachable",
      Errno::ECONNREFUSED.new => "unreachable"
    }

    failures.each do |error, name|
      answer = HTTPX::ErrorResponse.new(HTTPX::Request.new("GET", uri.to_s, HTTPX::Options.new), error)
      with_session(answer) do
        raised = assert_raises(DppService::Transport::Error) do
          DppService::Transport.call(Net::HTTP::Get.new("/"), uri, timeout: 5)
        end
        assert_equal name, raised.message
      end
    end
  end

  test "the client still reads the service's answer, commitment and all" do
    answer = ok_answer(headers: { "content-type" => "application/json; charset=utf-8",
                                  "x-dpp-payload-hash" => "zQmPayload", "x-dpp-commit-state" => "pending" },
                       body: JSON.generate("digitalProductPassportId" => "did:oyd:zQmPassport"))

    with_session(answer) do
      result = DppService::Client.read("https://dpp-service.example/dpp/v1/dpps/x")

      assert result.ok?
      assert_equal "did:oyd:zQmPassport", result.document["digitalProductPassportId"]
      assert result.commitment.pending?
    end
  end

  test "an unreachable service is reported as such by the client and the directory" do
    answer = HTTPX::ErrorResponse.new(HTTPX::Request.new("GET", uri.to_s, HTTPX::Options.new),
                                      HTTPX::ResolveError.new("no such host"))
    with_session(answer) do
      raised = assert_raises(DppService::Client::Error) { DppService::Client.read("https://dpp-service.example/x") }
      assert_equal "unreachable", raised.message

      assert_equal :unreachable, DppService::Directory.probe("https://dpp-service.example").message
    end
  end
end
