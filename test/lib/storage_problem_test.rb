require "test_helper"

# A data directory the container cannot write to. Before, this surfaced as a 500
# out of the SQLite adapter on the page where somebody had just typed a
# passphrase; now the unlock screen says what it saw and nothing is written.
class StorageProblemTest < ActionDispatch::IntegrationTest
  setup { reset_vault! }

  teardown do
    FileUtils.chmod(0o700, Vault::Store.data_dir)
    Vault::Store.close!
  end

  test "a writable directory is no problem" do
    assert_nil Vault::Store.storage_problem
    assert_empty data_dir_entries, "the write test leaves nothing behind"
  end

  test "a directory this process cannot write to is named, with the user id" do
    skip "root writes everywhere; the permission check cannot fail for it" if Process.euid.zero?

    FileUtils.chmod(0o500, Vault::Store.data_dir)
    kind, facts = Vault::Store.storage_problem

    assert_equal :directory_not_writable, kind
    assert_equal Vault::Store.data_dir.to_s, facts[:directory]
    assert_equal Process.euid, facts[:uid]
  end

  test "the unlock screen explains the problem instead of failing" do
    problem = [ :directory_not_writable, { directory: "/data", uid: 1000 } ]
    stubbing(Vault::Store, :storage_problem, ->(*) { problem }) do
      get unlock_path
      assert_response :success
      assert_match I18n.t("unlock.storage.title"), response.body
      assert_match "/data", response.body

      post unlock_path, params: { passphrase: TEST_PASSPHRASE, passphrase_confirmation: TEST_PASSPHRASE }
      assert_response :service_unavailable
      assert_includes CGI.unescapeHTML(response.body), I18n.t("unlock.storage.fix")
    end

    refute Vault::Store.exists?, "nothing was written"
  end

  # Typing a passphrase into a page that cannot store anything would only be
  # lost. The form stays visible, so the page still says what it is for.
  test "while the data file cannot be stored, the passphrase cannot be entered" do
    problem = [ :directory_not_writable, { directory: "/data", uid: 1000 } ]
    stubbing(Vault::Store, :storage_problem, ->(*) { problem }) do
      get unlock_path
      assert_select "input#passphrase[disabled]"
      assert_select "input#passphrase_confirmation[disabled]"
      assert_select "input[type=submit][disabled]"
      assert_select "p.hint", text: I18n.t("unlock.storage.disabled")
      assert_match "Docker Desktop on macOS or Windows", response.body

      stubbing(Vault::Store, :exists?, ->(*) { true }) do
        get unlock_path
        assert_select "input#passphrase[disabled]"
        assert_select "input[type=submit][disabled]"
      end
    end

    get unlock_path
    assert_select "input#passphrase:not([disabled])"
    assert_select "input[type=submit][disabled]", count: 0
  end

  test "a write refused by SQLite after the check is shown the same way" do
    stubbing(Vault::Lifecycle, :create!, ->(*, **) { raise SQLite3::CantOpenException, "unable to open database file" }) do
      post unlock_path, params: { passphrase: TEST_PASSPHRASE, passphrase_confirmation: TEST_PASSPHRASE }
    end

    assert_response :service_unavailable
    assert_match I18n.t("unlock.storage.title"), response.body
    refute Vault::Session.open?
  end
end
