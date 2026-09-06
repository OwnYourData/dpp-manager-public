require "test_helper"

class VaultPageTest < ActionDispatch::IntegrationTest
  setup { reset_vault!; create_and_unlock }
  teardown { Vault::Store.close! }

  test "a backup copy is written into the data directory and logged" do
    post vault_backup_path

    assert_redirected_to vault_path
    backups = data_dir_entries.grep(/\Adpp-\d{8}-\d{6}\.db\z/)
    assert_equal 1, backups.length, "expected exactly one backup file, saw #{data_dir_entries.inspect}"
    assert_equal backups.first, Event.where(kind: "backup_created").last.detail_hash["filename"]
  end

  test "the vault page lists the backup copies it has taken" do
    post vault_backup_path
    get vault_path

    assert_response :success
    assert_select "table td code", /\Adpp-\d{8}-\d{6}\.db\z/
  end

  test "changing the passphrase through the form works and is logged" do
    post vault_passphrase_path, params: {
      current_passphrase: TEST_PASSPHRASE,
      new_passphrase: "an entirely different passphrase",
      new_passphrase_confirmation: "an entirely different passphrase"
    }

    assert_redirected_to vault_path
    assert_equal 1, Event.where(kind: "passphrase_changed").count

    Vault::Store.close!
    refute Vault::Lifecycle.unlock!(TEST_PASSPHRASE)
    assert Vault::Lifecycle.unlock!("an entirely different passphrase")
  end

  test "a wrong current passphrase is refused and changes nothing" do
    post vault_passphrase_path, params: {
      current_passphrase: "not the current one",
      new_passphrase: "an entirely different passphrase",
      new_passphrase_confirmation: "an entirely different passphrase"
    }

    assert_response :unprocessable_entity
    assert_equal 0, Event.where(kind: "passphrase_changed").count

    Vault::Store.close!
    assert Vault::Lifecycle.unlock!(TEST_PASSPHRASE), "the original passphrase must still work"
  end

  test "a mismatched new passphrase is refused before the file is touched" do
    salt_before = Vault::Store.stored_salt

    post vault_passphrase_path, params: {
      current_passphrase: TEST_PASSPHRASE,
      new_passphrase: "an entirely different passphrase",
      new_passphrase_confirmation: "typed it wrong the second time"
    }

    assert_response :unprocessable_entity
    assert_equal salt_before, Vault::Store.stored_salt
  end

  test "the event log reports the chain as intact" do
    get events_path

    assert_response :success
    assert_select "p.chain-ok"
    assert_select "p.flash.alert", false
  end

  test "the event log can be filtered by kind" do
    post vault_backup_path
    get events_path(kind: "backup_created")

    assert_response :success
    assert_select "tbody tr", 1
  end
end
