require "test_helper"

class BootAndUnlockTest < ActionDispatch::IntegrationTest
  setup { reset_vault! }
  teardown { Vault::Store.close! }

  test "the health check answers while the vault is still locked and touches no database" do
    refute Vault::Store.exists?

    # If anything on this path connected, the adapter would ask
    # Vault::Session for a key and raise NotOpenError.
    get "/up"

    assert_response :success
    assert_equal "ok", JSON.parse(response.body)["status"]
    refute Vault::Session.open?
  end

  test "every page redirects to the unlock screen while the vault is closed" do
    [ root_path, settings_path, events_path, vault_path ].each do |path|
      get path
      assert_redirected_to unlock_path, "#{path} must not be reachable with the vault closed"
    end
  end

  test "the unlock screen offers creation when no file exists" do
    get unlock_path

    assert_response :success
    assert_select "input#passphrase_confirmation"
  end

  test "creating the vault from the form leads into the application" do
    post unlock_path, params: { passphrase: TEST_PASSPHRASE, passphrase_confirmation: TEST_PASSPHRASE }

    assert_redirected_to root_path
    follow_redirect!
    assert_response :success
    assert Vault::Store.exists?
  end

  test "a too short passphrase is refused without creating a file" do
    post unlock_path, params: { passphrase: "short", passphrase_confirmation: "short" }

    assert_response :unprocessable_entity
    refute Vault::Store.exists?
  end

  test "a mismatched confirmation is refused without creating a file" do
    post unlock_path, params: { passphrase: TEST_PASSPHRASE, passphrase_confirmation: "something else here" }

    assert_response :unprocessable_entity
    refute Vault::Store.exists?
  end

  test "the unlock screen asks only for the passphrase once a file exists" do
    create_and_unlock
    delete lock_path

    get unlock_path
    assert_response :success
    assert_select "input#passphrase"
    assert_select "input#passphrase_confirmation", false
  end

  test "a wrong passphrase is refused and the application stays locked" do
    create_and_unlock
    delete lock_path

    post unlock_path, params: { passphrase: "not the passphrase at all" }

    assert_response :unprocessable_entity
    get root_path
    assert_redirected_to unlock_path
  end

  test "locking closes the vault" do
    create_and_unlock
    assert Vault::Store.open?

    delete lock_path
    assert_redirected_to unlock_path
    refute Vault::Store.open?
  end
end
