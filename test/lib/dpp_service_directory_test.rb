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
end
