require "test_helper"

# The vault locking itself while somebody is in the middle of something.
#
# What has to hold: the action that arrives after the lock is not carried out,
# not even partly; the lock is in the event log, with what was not done; the
# unlock screen says so, and unlocking leads back to the page the action was
# sent from, with a message and the name of the form whose values the browser
# can put back. The values themselves never reach the server again.
class IdleLockTest < ActionDispatch::IntegrationTest
  include ActiveSupport::Testing::TimeHelpers

  IDENTIFIER = "https://id.example.com/01/09520123456788/21/000123".freeze

  setup do
    reset_vault!
    create_and_unlock
    Setting.current.update!(idle_timeout_minutes: 15)
  end

  teardown do
    travel_back
    Vault::Store.close!
  end

  test "the connection pool does not close the vault behind the idle timer's back" do
    pool = ActiveRecord::Base.connection_pool
    assert_nil pool.db_config.idle_timeout, "the reaper must not flush the vault's connection"

    get root_path
    pool.flush
    assert Vault::Store.open?, "a reaper pass leaves the vault open"
  end

  test "an action sent after the idle limit is not carried out and the lock is logged" do
    get setup_path(step: "custodian")
    travel 16.minutes

    post setup_custodian_path,
         params: { custodian_choice: "other", custodian_base_url: "https://pod.example.com",
                   custodian_collection_id: "42" },
         headers: { "HTTP_REFERER" => "http://www.example.com/setup?step=custodian" }

    assert_redirected_to unlock_path
    refute Vault::Store.open?

    open_vault
    assert_nil Setting.current.custodian_base_url, "the custodian was not configured"
    lock = Event.where(kind: "vault_locked").last
    assert_equal "idle", lock.detail_hash["reason"]
    assert_equal "POST /setup/custodian", lock.detail_hash["not_carried_out"]
  end

  test "the unlock screen says that the action was not carried out" do
    get root_path
    travel 16.minutes
    post setup_custodian_path, params: { custodian_collection_id: "42" },
                               headers: { "HTTP_REFERER" => "http://www.example.com/setup?step=custodian" }
    follow_redirect!

    assert_response :success
    assert_match I18n.t("vault.locked_after_idle_action"), response.body
    assert_match I18n.t("unlock.existing.interrupted"), response.body
  end

  test "unlocking leads back to the form, says why, and names the form to restore" do
    get root_path
    travel 16.minutes
    post setup_custodian_path, params: { custodian_collection_id: "42", custodian_base_url: "https://pod.example.com" },
                               headers: { "HTTP_REFERER" => "http://www.example.com/setup?step=custodian" }

    post unlock_path, params: { passphrase: TEST_PASSPHRASE }
    assert_redirected_to "/setup?step=custodian"

    follow_redirect!
    assert_response :success
    assert_match I18n.t("vault.action_not_done_after_unlock"), response.body
    assert_select "body[data-resume-restore-value=?]", setup_custodian_path
    assert_no_match "pod.example.com", response.body, "the typed values come back from the browser, not the server"
  end

  test "a confirmed click that arrives after the lock creates no identifier" do
    passport = ready_passport
    get edit_passport_path(passport)
    travel 16.minutes

    called = false
    stubbing(Did::Oyd, :mint_passport, ->(*, **) { called = true; {} }) do
      post mint_passport_path(passport), headers: { "HTTP_REFERER" => "http://www.example.com#{edit_passport_path(passport)}" }
    end

    assert_redirected_to unlock_path
    refute called, "the registry was never asked"

    post unlock_path, params: { passphrase: TEST_PASSPHRASE }
    assert_redirected_to edit_passport_path(passport)
    assert_nil passport.reload.dpp_id
    assert_equal "draft", passport.status
  end

  test "a page asked for after the lock is where unlocking leads, without a message about an action" do
    get root_path
    travel 16.minutes
    get events_path

    assert_redirected_to unlock_path
    post unlock_path, params: { passphrase: TEST_PASSPHRASE }
    assert_redirected_to events_path
    follow_redirect!
    assert_no_match I18n.t("vault.action_not_done_after_unlock"), response.body
    assert_select "body[data-resume-restore-value]", false
  end

  test "a referer from another host never becomes the way back" do
    get root_path
    travel 16.minutes
    post setup_custodian_path, params: { custodian_collection_id: "42" },
                               headers: { "HTTP_REFERER" => "https://elsewhere.example/phish" }

    post unlock_path, params: { passphrase: TEST_PASSPHRASE }
    assert_redirected_to root_path
  end

  test "an action that finds the vault already closed is not carried out either" do
    get root_path
    Vault::Lifecycle.lock!(reason: "manual")

    post setup_custodian_path, params: { custodian_collection_id: "42" },
                               headers: { "HTTP_REFERER" => "http://www.example.com/setup?step=custodian" }
    assert_redirected_to unlock_path

    post unlock_path, params: { passphrase: TEST_PASSPHRASE }
    assert_redirected_to "/setup?step=custodian"
    assert_nil Setting.current.custodian_collection_id
  end

  test "locking on purpose forgets the way back" do
    get root_path
    travel 16.minutes
    get events_path
    travel_back

    post unlock_path, params: { passphrase: TEST_PASSPHRASE }
    delete lock_path
    post unlock_path, params: { passphrase: TEST_PASSPHRASE }
    assert_redirected_to root_path
  end

  test "a link fetched ahead by Turbo does not keep the vault open" do
    get root_path
    travel 10.minutes
    get events_path, headers: { "X-Sec-Purpose" => "prefetch" }
    travel 6.minutes

    get events_path
    assert_redirected_to unlock_path
  end

  private

  def open_vault
    post unlock_path, params: { passphrase: TEST_PASSPHRASE }
  end

  def ready_passport
    Setting.current.update!(service_base_url: "https://dpp-service.example",
                            service_audience: "https://dpp-service.example")
    product_type = ProductType.create!(
      label: "Lamp", structure_name: "Lamp", repo_base_url: "https://soya.example",
      jsonld: '{"@graph":[]}', forms: { "en" => { "schema" => { "properties" => {} }, "ui" => {} } }.to_json,
      fetched_at: Time.current
    )
    Passport.create!(product_type: product_type, label: "Batch A",
                     unique_product_identifier: IDENTIFIER, granularity: "item")
  end
end
