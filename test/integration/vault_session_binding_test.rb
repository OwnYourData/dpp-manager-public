require "test_helper"

# An open vault belongs to the browser session that opened it.
#
# What has to hold: another session sees the vault as locked and is told that it
# is open elsewhere; the right passphrase there takes it over and the first
# session learns so on its next request; a wrong passphrase there changes
# nothing for the first session; another session can neither lock the vault nor
# keep it open, but its requests do close a vault whose holder has been away
# too long; locking and the idle limit leave no token that still fits; and the
# way back after an interrupted request works on both sides of a takeover.
class VaultSessionBindingTest < ActionDispatch::IntegrationTest
  include ActiveSupport::Testing::TimeHelpers

  REFERER = { "HTTP_REFERER" => "http://www.example.com/setup?step=custodian" }.freeze

  setup do
    reset_vault!
    create_and_unlock
    Setting.current.update!(idle_timeout_minutes: 15)
    @other = open_session
  end

  teardown do
    travel_back
    Vault::Store.close!
  end

  test "another session sees the vault as locked and is told that it is open elsewhere" do
    @other.get root_path
    @other.assert_redirected_to unlock_path

    @other.get unlock_path
    @other.assert_response :success
    assert_match I18n.t("unlock.existing.held_elsewhere"), @other.response.body

    assert Vault::Store.open?, "the vault itself stays open"
    get root_path
    assert_response :success
  end

  test "the session that opened the vault is not sent to the unlock screen" do
    get unlock_path
    assert_redirected_to root_path
  end

  test "the right passphrase in another session takes the vault over and locks the first" do
    first_token = session[:vault_holder]

    @other.post unlock_path, params: { passphrase: TEST_PASSPHRASE }
    @other.assert_redirected_to root_path
    @other.get root_path
    @other.assert_response :success

    refute Vault::Session.held_by?(first_token)
    assert Vault::Session.held_by?(@other.session[:vault_holder])

    get root_path
    assert_redirected_to unlock_path
    follow_redirect!
    assert_match I18n.t("vault.taken_over"), response.body

    opened = Event.where(kind: "vault_opened").last
    assert_equal true, opened.detail_hash["taken_over"]
  end

  test "the first session is told about the takeover once, not on every request after it" do
    @other.post unlock_path, params: { passphrase: TEST_PASSPHRASE }

    get root_path
    follow_redirect!
    assert_match I18n.t("vault.taken_over"), response.body

    get root_path
    follow_redirect!
    assert_no_match I18n.t("vault.taken_over"), response.body
  end

  test "a wrong passphrase in another session leaves the vault open and bound to the first" do
    first_token = session[:vault_holder]

    @other.post unlock_path, params: { passphrase: "not the passphrase at all" }
    @other.assert_response :unprocessable_entity
    assert_match I18n.t("vault.wrong_passphrase"), @other.response.body

    assert Vault::Store.open?, "the wrong attempt did not close the vault"
    assert Vault::Session.held_by?(first_token)
    get root_path
    assert_response :success

    @other.get root_path
    @other.assert_redirected_to unlock_path
    assert_equal 1, Vault::Lifecycle.failures_since_last_unlock
  end

  test "deriving and the delay after a wrong passphrase do not hold the holder's lock" do
    token = session[:vault_holder]
    answered = ->(label) {
      reply = Thread.new { Vault::Session.held_by?(token) }.join(2)
      assert reply, "a request of the holder was held up during #{label}"
      assert reply.value
    }
    derive = Vault::Kdf.method(:derive)

    stubbing(Vault::Kdf, :derive, ->(*args, **kwargs) { answered.call("the derivation"); derive.call(*args, **kwargs) }) do
      stubbing(Vault::Lifecycle, :sleep, ->(*) { answered.call("the delay") }) do
        assert_nil Vault::Lifecycle.take_over!("not the passphrase at all")
      end
    end
  end

  test "another session cannot lock the vault" do
    @other.delete lock_path
    @other.assert_redirected_to unlock_path

    assert Vault::Store.open?
    get root_path
    assert_response :success
    assert_empty Event.where(kind: "vault_locked")
  end

  test "a request from another session after the idle limit locks the vault as idle" do
    get root_path
    travel 16.minutes

    @other.get root_path
    @other.assert_redirected_to unlock_path
    refute Vault::Store.open?

    post unlock_path, params: { passphrase: TEST_PASSPHRASE }
    lock = Event.where(kind: "vault_locked").last
    assert_equal "idle", lock.detail_hash["reason"]
    assert_nil lock.detail_hash["not_carried_out"], "the other session's request is not the holder's action"
  end

  test "the unlock page of another session closes a vault whose holder has gone, and offers no takeover" do
    get root_path
    travel 16.minutes

    @other.get unlock_path
    refute Vault::Store.open?
    assert_no_match I18n.t("unlock.existing.held_elsewhere"), @other.response.body
  end

  test "requests of another session do not keep the vault open" do
    get root_path
    travel 10.minutes
    @other.get root_path
    travel 6.minutes

    get root_path
    assert_redirected_to unlock_path
    follow_redirect!
    assert_match I18n.t("vault.locked_after_idle"), response.body
  end

  test "locking leaves no token that still fits" do
    token = session[:vault_holder]
    delete lock_path

    refute Vault::Session.held_by?(token)
    assert_nil session[:vault_holder]

    post unlock_path, params: { passphrase: TEST_PASSPHRASE }
    refute_equal token, session[:vault_holder]
    refute Vault::Session.held_by?(token), "an old cookie does not open the vault again"
  end

  test "the idle limit leaves no token that still fits" do
    token = session[:vault_holder]
    get root_path
    travel 16.minutes
    get root_path

    assert_redirected_to unlock_path
    refute Vault::Session.held_by?(token)
    assert_nil Vault::Session.last_seen_at
    assert_nil session[:vault_holder]
  end

  test "a page asked for in another session is where taking over leads" do
    @other.get events_path
    @other.assert_redirected_to unlock_path

    @other.post unlock_path, params: { passphrase: TEST_PASSPHRASE }
    @other.assert_redirected_to events_path
  end

  test "an action of the first session after the takeover is not carried out and leads back to its form" do
    @other.post unlock_path, params: { passphrase: TEST_PASSPHRASE }

    post setup_custodian_path, params: { custodian_choice: "other", custodian_base_url: "https://pod.example.com",
                                         custodian_collection_id: "42" }, headers: REFERER
    assert_redirected_to unlock_path
    follow_redirect!
    assert_match I18n.t("vault.taken_over"), response.body
    assert_match I18n.t("vault.action_not_done"), response.body

    post unlock_path, params: { passphrase: TEST_PASSPHRASE }
    assert_redirected_to "/setup?step=custodian"
    follow_redirect!
    assert_match I18n.t("vault.action_not_done_after_unlock"), response.body
    assert_select "body[data-resume-restore-value=?]", setup_custodian_path
    assert_nil Setting.current.custodian_base_url, "the custodian was not configured"
  end

  test "changing the passphrase keeps the vault bound to the session that changed it" do
    fresh = "another correct horse battery staple"
    post vault_passphrase_path, params: { current_passphrase: TEST_PASSPHRASE, new_passphrase: fresh,
                                          new_passphrase_confirmation: fresh }
    assert_redirected_to vault_path

    get root_path
    assert_response :success

    @other.post unlock_path, params: { passphrase: fresh }
    @other.assert_redirected_to root_path
  end
end
