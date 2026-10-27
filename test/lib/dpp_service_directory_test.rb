require "test_helper"

# What this application reads from a DPP Service's discovery document.
class DppServiceDirectoryTest < ActiveSupport::TestCase
  DISCOVERY = {
    "did" => "did:oyd:zQmService",
    "readers" => [
      { "pod" => "https://dpp-staging.go-data.at", "did" => "did:oyd:zQmStagingReader" },
      { "pod" => "https://dpp.go-data.at", "did" => "did:oyd:zQmProductionReader" }
    ]
  }.freeze

  test "the reader for a custodian is the one the service lists for that pod" do
    asked = nil
    discovery = ->(uri) { asked = uri.to_s; DISCOVERY }

    stubbing(DppService::Directory, :get_json, discovery) do
      assert_equal "did:oyd:zQmProductionReader",
                   DppService::Directory.reader_for("https://dpp-service.example/", "https://DPP.go-data.at/")
    end
    assert_equal "https://dpp-service.example/.well-known/dpp-service", asked
  end

  test "there is no reader for a custodian the service does not list, or when it cannot be asked" do
    stubbing(DppService::Directory, :get_json, ->(_uri) { DISCOVERY }) do
      assert_nil DppService::Directory.reader_for("https://dpp-service.example", "https://other.example")
      assert_nil DppService::Directory.reader_for("https://dpp-service.example", "")
    end
    stubbing(DppService::Directory, :get_json, ->(_uri) { { "did" => "did:oyd:zQmService" } }) do
      assert_nil DppService::Directory.reader_for("https://dpp-service.example", "https://dpp.go-data.at")
    end
    stubbing(DppService::Directory, :get_json, ->(_uri) { raise DppService::Directory::Error, "unreachable" }) do
      assert_nil DppService::Directory.reader_for("https://dpp-service.example", "https://dpp.go-data.at")
    end
  end

  test "the carrier hosts are the ones the service lists, in lower case and once each" do
    asked = nil
    discovery = ->(uri) { asked = uri.to_s; DISCOVERY.merge("carrierHosts" => [ "ID.example.org", " id.example.org ", "", "own.example" ]) }

    stubbing(DppService::Directory, :get_json, discovery) do
      assert_equal %w[id.example.org own.example], DppService::Directory.carrier_hosts("https://dpp-service.example/")
    end
    assert_equal "https://dpp-service.example/.well-known/dpp-service", asked
  end

  test "a service that lists no carrier host has none, and one that cannot be asked gives no answer" do
    stubbing(DppService::Directory, :get_json, ->(_uri) { DISCOVERY }) do
      assert_equal [], DppService::Directory.carrier_hosts("https://dpp-service.example")
    end
    stubbing(DppService::Directory, :get_json, ->(_uri) { nil }) do
      assert_nil DppService::Directory.carrier_hosts("https://dpp-service.example")
    end
    stubbing(DppService::Directory, :get_json, ->(_uri) { raise DppService::Directory::Error, "unreachable" }) do
      assert_nil DppService::Directory.carrier_hosts("https://dpp-service.example")
    end
    assert_nil DppService::Directory.carrier_hosts("")
  end

  test "probing a service reads its carrier hosts along with its DID" do
    answers = lambda do |uri|
      uri.path == "/up" ? { "status" => "ok" } : DISCOVERY.merge("carrierHosts" => [ "id.example.org" ])
    end

    stubbing(DppService::Directory, :get_json, answers) do
      result = DppService::Directory.probe("https://dpp-service.example")
      assert result.reachable?
      assert_equal %w[id.example.org], result.carrier_hosts
    end
  end
end
