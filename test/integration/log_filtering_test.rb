require "test_helper"

# What a request leaves in the log. In production the log goes to the
# container's standard output at level info, and the line with the request
# parameters is written at that level: whatever is not filtered there stays in
# `docker logs` for as long as the container exists. The SQL log is only
# written at level debug, but anybody can switch to it with RAILS_LOG_LEVEL.
#
# Each form that takes a secret is sent once, with the whole log captured, and
# the secret must not appear in it anywhere: neither in the parameters nor in a
# statement nor in an error.
class LogFilteringTest < ActionDispatch::IntegrationTest
  setup { reset_vault! }
  teardown { Vault::Store.close! }

  test "creating the vault logs neither the passphrase nor its confirmation" do
    log = capturing_log { create_and_unlock }

    assert_redirected_to root_path
    assert_filtered log, "passphrase", "passphrase_confirmation"
    refute_includes log, TEST_PASSPHRASE
    refute_key_material log
  end

  test "unlocking does not log the passphrase" do
    create_and_unlock
    delete lock_path

    log = capturing_log { post unlock_path, params: { passphrase: TEST_PASSPHRASE } }

    assert_redirected_to root_path
    assert_filtered log, "passphrase"
    refute_includes log, TEST_PASSPHRASE
    refute_key_material log
  end

  test "a wrong passphrase is not logged either" do
    create_and_unlock
    delete lock_path
    wrong = "a wrong guess that is long enough"

    log = capturing_log { post unlock_path, params: { passphrase: wrong } }

    assert_response :unprocessable_entity
    assert_filtered log, "passphrase"
    refute_includes log, wrong
  end

  test "changing the passphrase logs none of the three fields and not the new key" do
    create_and_unlock
    fresh = "a passphrase nobody should ever read"

    log = capturing_log do
      post vault_passphrase_path, params: {
        current_passphrase: TEST_PASSPHRASE,
        new_passphrase: fresh,
        new_passphrase_confirmation: fresh
      }
    end

    assert_redirected_to vault_path
    assert_filtered log, "current_passphrase", "new_passphrase", "new_passphrase_confirmation"
    refute_includes log, TEST_PASSPHRASE
    refute_includes log, fresh
    refute_key_material log
  end

  test "importing an identity logs neither of its keys" do
    create_and_unlock
    configure_service!
    document_key = "z1S5ImportedDocKey"
    revocation_key = "z1S5ImportedRevKey"

    log = stubbing(Did::Oyd, :key_matches?, ->(_did, _key) { true }) do
      capturing_log do
        post setup_import_identity_path, params: {
          did: "did:oyd:zQmimportedbase5823456789234567892345",
          document_key: document_key, revocation_key: revocation_key
        }
      end
    end

    assert_redirected_to setup_path
    assert Identity.current, "the import itself has to have worked"
    assert_filtered log, "document_key", "revocation_key"
    refute_includes log, document_key
    refute_includes log, revocation_key
  end

  test "minting an identity writes its keys and revocation log without logging them" do
    create_and_unlock
    configure_service!
    minted = { did: "did:oyd:zQmMintedbase58234567892345678923456789",
               document_key: "z1S5MintedDocKey",
               revocation_key: "z1S5MintedRevKey",
               revocation_log: '{"minted-revocation-log":"never logged"}' }

    log = stubbing(Did::Oyd, :mint, ->(_content = {}) { minted }) do
      capturing_log { post setup_mint_identity_path, params: { label: "Lumina GmbH" } }
    end

    assert_redirected_to setup_path(step: "keys")
    assert Identity.current, "the identity itself has to have been stored"
    refute_includes log, minted[:document_key]
    refute_includes log, minted[:revocation_key]
    refute_includes log, "minted-revocation-log"
  end

  private

  # Everything any part of the application writes to the log while the block
  # runs: request lines, parameters, SQL, errors. At level debug, the most that
  # can be switched on.
  def capturing_log
    io = StringIO.new
    capture = ActiveSupport::Logger.new(io)
    capture.level = Logger::DEBUG
    Rails.logger.broadcast_to(capture)
    yield
    io.string
  ensure
    Rails.logger.stop_broadcasting_to(capture) if capture
  end

  def assert_filtered(log, *names)
    names.each do |name|
      assert_match(/"#{Regexp.escape(name)}"\s*=>\s*"\[FILTERED\]"/, log, "#{name} is not shown as [FILTERED]")
    end
  end

  # The key the vault is open with: from it and the file, the contents can be
  # read without the passphrase.
  def refute_key_material(log)
    hex = Vault::Session.pragma_key_literal[/\h{64,}/]
    assert hex, "the vault has to be open to know its key"
    refute_includes log, hex
    refute_includes log, hex[0, 64]
  end

  def configure_service!
    Setting.current.update!(service_base_url: "https://svc.example",
                            service_audience: "https://svc.example",
                            service_did: "did:oyd:zQmServiceDid234567892345678923456789")
  end
end
