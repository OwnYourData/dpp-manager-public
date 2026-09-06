require "test_helper"

# The wizard, with the network stubbed out. What is being tested is the order of
# the steps and what cannot be skipped — not whether a registry answers.
class SetupTest < ActionDispatch::IntegrationTest
  setup do
    reset_vault!
    create_and_unlock
  end

  teardown { Vault::Store.close! }

  test "an unconfigured application starts the wizard at the service" do
    get setup_path

    assert_response :success
    assert_select "input#service_base_url"
  end

  test "a reachable service is recorded with the identity it publishes" do
    with_probe(reachable: true, did: "did:oyd:zQmServiceDid234567892345678923456789",
               audience: "https://svc.example") do
      post setup_service_path, params: { service_base_url: "svc.example" }
    end

    assert_redirected_to setup_path
    assert_equal "https://svc.example", settings.reload.service_base_url
    assert_equal "did:oyd:zQmServiceDid234567892345678923456789", settings.service_did
    assert_equal "service_configured", Event.last.kind
  end

  test "an unreachable service is refused and nothing is stored" do
    with_probe(reachable: false, message: :unreachable) do
      post setup_service_path, params: { service_base_url: "https://nowhere.example" }
    end

    assert_response :unprocessable_entity
    assert_nil settings.reload.service_base_url
  end

  test "a malformed address never reaches the network" do
    post setup_service_path, params: { service_base_url: "not a url at all" }

    assert_response :unprocessable_entity
    assert_nil settings.reload.service_base_url
  end

  test "the wizard moves to the identity once the service is set" do
    configure_service!

    get setup_path
    assert_response :success
    assert_select "form[action=?]", setup_mint_identity_path
  end

  test "minting stores the keys and demands they be secured before anything else" do
    configure_service!
    with_mint { post setup_mint_identity_path, params: { label: "Lumina GmbH" } }

    identity = Identity.current
    assert_equal "did:oyd:zQmMintedbase58234567892345678923456789", identity.did
    assert_equal "minted", identity.origin
    assert_not identity.keys_secured?, "freshly minted keys are not secured yet"

    # And the wizard refuses to move on, however the operator arrives.
    get setup_path
    assert_select "code.secret"
  end

  test "the keys step cannot be passed without confirming" do
    configure_service!
    with_mint { post setup_mint_identity_path }

    post setup_keys_path
    assert_response :unprocessable_entity
    assert_not Identity.current.keys_secured?

    post setup_keys_path, params: { confirmed: "1" }
    assert_redirected_to setup_path
    assert Identity.current.reload.keys_secured?
    assert_equal "identity_keys_secured", Event.last.kind
  end

  test "an imported identity is checked against the registry before it is stored" do
    configure_service!
    stubbing(Did::Oyd, :key_matches?, ->(_did, _key) { false }) do
      post setup_import_identity_path, params: {
        did: "did:oyd:zQmimportedbase5823456789234567892345",
        document_key: "z1S5NotTheRightKey"
      }
    end

    assert_response :unprocessable_entity
    assert_nil Identity.current
  end

  test "an imported identity counts as already secured — it came from somewhere" do
    configure_service!
    stubbing(Did::Oyd, :key_matches?, ->(_did, _key) { true }) do
      post setup_import_identity_path, params: {
        did: "did:oyd:zQmimportedbase5823456789234567892345",
        document_key: "z1S5TheRightKey", revocation_key: "z1S5Revocation"
      }
    end

    identity = Identity.current
    assert_equal "imported", identity.origin
    assert identity.keys_secured?
    assert identity.revocable?
  end

  test "an import without the document key is refused before any lookup" do
    configure_service!

    post setup_import_identity_path, params: { did: "did:oyd:zQmsomethingbase58234567892345678" }

    assert_response :unprocessable_entity
    assert_nil Identity.current
  end

  test "the custodian can be skipped and the setup still completes" do
    ready_for_custodian!

    post setup_custodian_path, params: { skip: "1" }

    assert_redirected_to root_path
    assert settings.reload.setup_complete?
    assert_not settings.custodian_configured?
  end

  test "a custodian address too long for a data carrier is refused" do
    ready_for_custodian!

    post setup_custodian_path, params: {
      custodian_base_url: "https://a-really-quite-long-custodian-name.example.org",
      custodian_collection_id: "4"
    }

    assert_response :unprocessable_entity
    assert_not settings.reload.custodian_configured?
  end

  test "a custodian address without a collection is refused" do
    ready_for_custodian!

    post setup_custodian_path, params: { custodian_base_url: "https://dpp.go-data.at" }

    assert_response :unprocessable_entity
    assert_not settings.reload.custodian_configured?
  end

  test "a complete custodian finishes the setup" do
    ready_for_custodian!

    post setup_custodian_path, params: {
      custodian_base_url: "https://dpp.go-data.at", custodian_collection_id: "31"
    }

    assert_redirected_to root_path
    assert settings.reload.custodian_configured?
    assert settings.setup_complete?
  end

  test "the wizard cannot be skipped ahead of where the state actually is" do
    get setup_path(step: "custodian")

    assert_response :success
    assert_select "input#service_base_url",
      { count: 1 }, "asking for a step ahead has to fall back to the step the state is actually at"
  end

  # The one custodian offered by name. Its address comes from the application,
  # not from the form: somebody who picked it off the list never typed one, and
  # that address is frozen into every identifier minted afterwards.
  test "the named custodian needs no address typed in" do
    ready_for_custodian!

    post setup_custodian_path, params: { custodian_choice: "known", custodian_collection_id: "121" }

    assert settings.reload.custodian_configured?
    assert_equal Setting::KNOWN_CUSTODIAN[:base_url], settings.custodian_base_url
    assert_equal "121", settings.custodian_collection_id
  end

  # Changing it later is an ordinary edit and not the end of the wizard: it goes
  # back where it was opened from, and the setup is not completed a second time.
  test "changing the custodian afterwards returns to the settings" do
    ready_for_custodian!
    post setup_custodian_path, params: { custodian_choice: "known", custodian_collection_id: "121" }
    finished_at = settings.reload.setup_completed_at

    post setup_custodian_path, params: { custodian_choice: "other",
                                         custodian_base_url: "https://pod.example",
                                         custodian_collection_id: "7" }

    assert_redirected_to settings_path
    assert_equal "https://pod.example", settings.reload.custodian_base_url
    assert_equal "7", settings.custodian_collection_id
    assert_equal finished_at, settings.setup_completed_at
  end

  test "removing the custodian afterwards leaves the setup finished" do
    ready_for_custodian!
    post setup_custodian_path, params: { custodian_choice: "known", custodian_collection_id: "121" }

    post setup_custodian_path, params: { skip: "1" }

    assert_redirected_to settings_path
    assert_not settings.reload.custodian_configured?
    assert settings.setup_complete?
  end

  private

  def settings = Setting.current

  # The wizard's network calls are replaced wholesale. What is under test is the
  # order of the steps and what cannot be skipped; whether a registry answers is
  # the wizard's problem at runtime, not the test's.
  def with_probe(**attrs, &block)
    result = DppService::Directory::Result.new(**attrs)
    stubbing(DppService::Directory, :probe, ->(_base) { result }, &block)
  end

  def configure_service!
    Setting.current.update!(service_base_url: "https://svc.example",
                            service_audience: "https://svc.example",
                            service_did: "did:oyd:zQmServiceDid234567892345678923456789")
  end

  def with_mint(&block)
    minted = { did: "did:oyd:zQmMintedbase58234567892345678923456789",
               document_key: "z1S5DocumentKey", revocation_key: "z1S5RevocationKey",
               revocation_log: '{"ts":1}' }
    stubbing(Did::Oyd, :mint, ->(_content = {}) { minted }, &block)
  end

  def ready_for_custodian!
    configure_service!
    Identity.create!(did: "did:oyd:zQmReadybase5823456789234567892345678",
                     origin: "minted", document_key: "z1S5Doc", revocation_key: "z1S5Rev",
                     keys_secured_at: Time.current)
  end
end
