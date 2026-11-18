require "test_helper"

class DeploymentTest < ActiveSupport::TestCase
  VARIABLES = %w[DPP_SERVICE_URL DPP_NOINDEX DPP_KNOWN_CUSTODIAN DPP_SECURE_COOKIES].freeze

  setup do
    @saved = VARIABLES.to_h { |name| [ name, ENV[name] ] }
    VARIABLES.each { |name| ENV.delete(name) }
  end

  teardown { @saved.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value } }

  test "without any variable everything is as on one's own computer" do
    assert_nil Deployment.service_url
    refute Deployment.noindex?
    assert Deployment.known_custodian_offered?
    refute Deployment.secure_cookies?
    assert_equal Setting::DEFAULT_SERVICE_BASE_URL, Setting.suggested_service_base_url
  end

  test "the flags take the usual spellings of yes, and nothing else" do
    %w[1 true TRUE yes on].each do |value|
      ENV["DPP_NOINDEX"] = value
      assert Deployment.noindex?, value
    end
    %w[0 false no off maybe].each do |value|
      ENV["DPP_NOINDEX"] = value
      refute Deployment.noindex?, value
    end
  end

  test "only an explicit no turns the named custodian off" do
    %w[off OFF false no 0].each do |value|
      ENV["DPP_KNOWN_CUSTODIAN"] = value
      refute Deployment.known_custodian_offered?, value
    end
    %w[on true anything].each do |value|
      ENV["DPP_KNOWN_CUSTODIAN"] = value
      assert Deployment.known_custodian_offered?, value
    end
  end

  test "the service address is normalised, and one that is not an address counts as unset" do
    ENV["DPP_SERVICE_URL"] = " https://dpp.example.com/ "
    assert_equal "https://dpp.example.com", Deployment.service_url
    assert_equal "https://dpp.example.com", Setting.suggested_service_base_url

    ENV["DPP_SERVICE_URL"] = "not an address"
    assert_nil Deployment.service_url
    assert_equal Setting::DEFAULT_SERVICE_BASE_URL, Setting.suggested_service_base_url
  end
end
