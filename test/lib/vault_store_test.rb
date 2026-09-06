require "test_helper"

class VaultStoreTest < ActiveSupport::TestCase
  setup { reset_vault! }
  teardown { Vault::Store.close! }

  test "creating a vault leaves exactly one file behind" do
    Vault::Lifecycle.create!(TEST_PASSPHRASE)
    Vault::Store.close!

    assert_equal [ "dpp.db" ], data_dir_entries,
      "no -wal, -shm or -journal may survive a clean close"
  end

  test "the first sixteen bytes of the file are the salt and are readable without a key" do
    Vault::Lifecycle.create!(TEST_PASSPHRASE)
    salt = Vault::Store.stored_salt
    Vault::Store.close!

    assert_equal 16, salt.bytesize
    assert_equal salt, Vault::Store.path.binread(16)
    refute_equal "\0" * 16, salt, "the salt must be random, not empty"
  end

  test "the right passphrase opens the vault again in a fresh connection" do
    Vault::Lifecycle.create!(TEST_PASSPHRASE)
    Event.record!(:backup_created, filename: "marker.db")
    Vault::Store.close!

    assert Vault::Lifecycle.unlock!(TEST_PASSPHRASE)
    assert_equal 1, Event.where(kind: "backup_created").count
  end

  test "a wrong passphrase does not open the vault and does not corrupt it" do
    Vault::Lifecycle.create!(TEST_PASSPHRASE)
    Vault::Store.close!

    refute Vault::Lifecycle.unlock!("wrong passphrase entirely")
    refute Vault::Store.open?

    assert Vault::Lifecycle.unlock!(TEST_PASSPHRASE), "the file must still be usable afterwards"
  end

  test "the payload is not readable as plain text in the file" do
    Vault::Lifecycle.create!(TEST_PASSPHRASE)
    Event.record!(:backup_created, filename: "a-very-distinctive-marker-4711")
    Vault::Store.close!

    raw = Vault::Store.path.binread
    refute_includes raw, "a-very-distinctive-marker-4711"
    refute_includes raw, "events", "not even the table names may be legible"
  end

  test "creating refuses to overwrite an existing vault" do
    Vault::Lifecycle.create!(TEST_PASSPHRASE)
    Vault::Store.close!

    assert_raises(Vault::AlreadyExistsError) { Vault::Store.create!("another passphrase") }
  end

  test "a copy of the file opens elsewhere with the same passphrase" do
    Vault::Lifecycle.create!(TEST_PASSPHRASE)
    Event.record!(:backup_created, filename: "carried-over.db")
    Vault::Store.close!

    Dir.mktmpdir("dpp-manager-elsewhere-") do |elsewhere|
      FileUtils.cp(Vault::Store.path.to_s, File.join(elsewhere, "dpp.db"))
      original = ENV["DPP_DATA_DIR"]

      begin
        ENV["DPP_DATA_DIR"] = elsewhere
        assert Vault::Lifecycle.unlock!(TEST_PASSPHRASE)
        assert_equal 1, Event.where(kind: "backup_created").count
      ensure
        Vault::Store.close!
        ENV["DPP_DATA_DIR"] = original
      end
    end
  end

  test "a backup copy is a complete vault of its own" do
    Vault::Lifecycle.create!(TEST_PASSPHRASE)
    Event.record!(:backup_created, filename: "before-backup.db")

    destination = Vault::Store.data_dir.join("dpp-backup-test.db")
    Vault::Store.backup!(destination)
    Vault::Store.close!

    assert destination.exist?
    # Same key, so the backup opens with the same passphrase: sqlcipher_export
    # through VACUUM INTO keeps the key and the salt.
    Dir.mktmpdir("dpp-manager-backup-") do |elsewhere|
      FileUtils.cp(destination.to_s, File.join(elsewhere, "dpp.db"))
      original = ENV["DPP_DATA_DIR"]
      begin
        ENV["DPP_DATA_DIR"] = elsewhere
        assert Vault::Lifecycle.unlock!(TEST_PASSPHRASE)
        assert_equal 1, Event.where(kind: "backup_created").count
      ensure
        Vault::Store.close!
        ENV["DPP_DATA_DIR"] = original
      end
    end
  end

  test "changing the passphrase invalidates the old one and keeps the data" do
    Vault::Lifecycle.create!(TEST_PASSPHRASE)
    Event.record!(:backup_created, filename: "survives-the-rekey.db")

    Vault::Store.change_passphrase!(TEST_PASSPHRASE, "a completely different passphrase")
    assert_equal 1, Event.where(kind: "backup_created").count, "data must survive the re-key"
    Vault::Store.close!

    assert_equal [ "dpp.db" ], data_dir_entries, "the temporary re-key file must be gone"

    refute Vault::Lifecycle.unlock!(TEST_PASSPHRASE), "the old passphrase must stop working"
    assert Vault::Lifecycle.unlock!("a completely different passphrase")
    assert_equal 1, Event.where(kind: "backup_created").count
  end

  test "changing the passphrase refuses a wrong current passphrase before touching the file" do
    Vault::Lifecycle.create!(TEST_PASSPHRASE)
    before = Vault::Store.path.binread(16)

    assert_raises(Vault::LockedError) do
      Vault::Store.change_passphrase!("not the current one", "a new passphrase entirely")
    end

    assert_equal before, Vault::Store.path.binread(16), "the salt must be untouched"
    assert_equal [ "dpp.db" ], data_dir_entries
  end

  test "the key never reaches disk and is cleared on close" do
    Vault::Lifecycle.create!(TEST_PASSPHRASE)
    assert Vault::Session.open?

    Vault::Store.close!
    refute Vault::Session.open?
    assert_raises(Vault::NotOpenError) { Vault::Session.pragma_key_literal }
  end
end
