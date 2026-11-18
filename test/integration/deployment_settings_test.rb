require "test_helper"

# What an operator can set through the environment for an installation that is
# not on one person's own computer: the suggested DPP Service, noindex, whether
# the named custodian is offered, and a session cookie for HTTPS only. Without
# any of them, everything is as on a laptop.
class DeploymentSettingsTest < ActionDispatch::IntegrationTest
  VARIABLES = %w[DPP_SERVICE_URL DPP_NOINDEX DPP_KNOWN_CUSTODIAN DPP_SECURE_COOKIES].freeze
  TEST_SERVICE = "https://dpp-service.test.example".freeze

  setup do
    @saved = VARIABLES.to_h { |name| [ name, ENV[name] ] }
    VARIABLES.each { |name| ENV.delete(name) }
    reset_vault!
  end

  teardown do
    @saved.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
    Vault::Store.close!
  end

  # --- DPP_SERVICE_URL ------------------------------------------------------

  test "without DPP_SERVICE_URL the setup suggests the public DPP Service" do
    create_and_unlock
    get setup_path

    assert_select "input#service_base_url[value=?]", Setting::DEFAULT_SERVICE_BASE_URL
    assert_select "a[href=?]", Setting::DEFAULT_SERVICE_BASE_URL
  end

  test "DPP_SERVICE_URL is what the setup suggests and the bar links to, the footer keeps the public one" do
    ENV["DPP_SERVICE_URL"] = "#{TEST_SERVICE}/"
    create_and_unlock
    get setup_path

    assert_select "input#service_base_url[value=?]", TEST_SERVICE
    assert_select "a[href=?]", TEST_SERVICE
    assert_select "footer a[href=?]", Setting::DEFAULT_SERVICE_BASE_URL
  end

  test "a DPP_SERVICE_URL that is not an address is ignored" do
    ENV["DPP_SERVICE_URL"] = "not an address"
    create_and_unlock
    get setup_path

    assert_select "input#service_base_url[value=?]", Setting::DEFAULT_SERVICE_BASE_URL
  end

  # --- DPP_NOINDEX ----------------------------------------------------------

  test "without DPP_NOINDEX there is neither the header nor the meta element" do
    get unlock_path

    assert_nil response.headers["x-robots-tag"]
    assert_select "meta[name=robots]", false
  end

  test "DPP_NOINDEX puts the header on every response and the meta element in both layouts" do
    ENV["DPP_NOINDEX"] = "true"

    get unlock_path
    assert_equal "noindex, nofollow", response.headers["x-robots-tag"]
    assert_select "meta[name=robots][content=?]", "noindex, nofollow"

    create_and_unlock
    get root_path
    assert_equal "noindex, nofollow", response.headers["x-robots-tag"]
    assert_select "meta[name=robots][content=?]", "noindex, nofollow"

    get "/up"
    assert_equal "noindex, nofollow", response.headers["x-robots-tag"], "the health check too"

    get "/robots.txt"
    assert_response :success
    assert_equal "noindex, nofollow", response.headers["x-robots-tag"], "static files too"
  end

  # --- DPP_KNOWN_CUSTODIAN --------------------------------------------------

  test "without DPP_KNOWN_CUSTODIAN the setup offers the named custodian" do
    create_and_unlock
    ready_for_custodian!
    get setup_path(step: "custodian")

    assert_select "input[type=radio][name=custodian_choice][value=known]"
    assert_match Setting::KNOWN_CUSTODIAN[:name], response.body
  end

  test "DPP_KNOWN_CUSTODIAN=off leaves only the field" do
    ENV["DPP_KNOWN_CUSTODIAN"] = "off"
    create_and_unlock
    ready_for_custodian!
    get setup_path(step: "custodian")

    assert_select "input[type=radio][name=custodian_choice]", false
    assert_select "input[type=hidden][name=custodian_choice][value=other]"
    assert_select "input#custodian_base_url"
    assert_no_match Setting::KNOWN_CUSTODIAN[:name], response.body
  end

  test "with DPP_KNOWN_CUSTODIAN=off the named custodian cannot be chosen either" do
    ENV["DPP_KNOWN_CUSTODIAN"] = "off"
    create_and_unlock
    ready_for_custodian!

    post setup_custodian_path, params: { custodian_choice: "known", custodian_collection_id: "121" }
    assert_response :unprocessable_entity
    assert_nil Setting.current.custodian_base_url

    post setup_custodian_path, params: { custodian_choice: "known", custodian_base_url: "https://pod.example.com",
                                         custodian_collection_id: "121" }
    assert_equal "https://pod.example.com", Setting.current.reload.custodian_base_url
  end

  # --- DPP_SECURE_COOKIES ---------------------------------------------------

  test "without DPP_SECURE_COOKIES the session cookie is not marked secure" do
    create_and_unlock

    assert_match(/_session=/, session_cookie_header)
    assert_no_match(/;\s*secure/i, session_cookie_header)
  end

  test "DPP_SECURE_COOKIES marks the session cookie secure" do
    ENV["DPP_SECURE_COOKIES"] = "true"
    https!
    create_and_unlock

    assert_match(/_session=/, session_cookie_header)
    assert_match(/;\s*secure/i, session_cookie_header)

    get root_path
    assert_response :success, "the cookie still carries the vault over HTTPS"
  end

  private

  def session_cookie_header
    Array(response.headers["set-cookie"]).join("\n").lines.grep(/_session=/).join
  end

  def ready_for_custodian!
    Setting.current.update!(service_base_url: "https://svc.example", service_audience: "https://svc.example",
                            service_did: "did:oyd:zQmServiceDid234567892345678923456789")
    Identity.create!(did: "did:oyd:zQmReadybase5823456789234567892345678",
                     origin: "minted", document_key: "z1S5Doc", revocation_key: "z1S5Rev",
                     keys_secured_at: Time.current)
  end
end
