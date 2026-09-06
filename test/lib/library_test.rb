require "test_helper"

# The one test that would have caught a day of confusion: a SQLite library that
# looks fine, builds fine, runs fine, and does not encrypt.
class LibraryTest < ActiveSupport::TestCase
  test "the sqlite library underneath is SQLCipher and not plain SQLite" do
    assert Vault::Library.encrypting?,
      "PRAGMA cipher_version is empty: this is plain SQLite, PRAGMA key would be " \
      "accepted and ignored, and the vault would be written unencrypted. " \
      "Saw: #{Vault::Library.describe}"
  end

  test "the sqlite version is new enough for Active Record" do
    assert Vault::Library.usable?,
      "Active Record needs SQLite >= #{Vault::Library::MINIMUM_SQLITE}. " \
      "Saw: #{Vault::Library.describe}"
  end

  # The identity is minted through rbnacl, which loads libsodium over FFI at the
  # moment a key is first generated and not before. Without this test the absence
  # of the library shows up in front of the operator, on the one screen that
  # cannot be repeated.
  test "libsodium is reachable, so an identity can actually be minted" do
    assert Vault::Library.sodium_available?,
      "rbnacl cannot reach libsodium. On Debian and Ubuntu: libsodium23."
  end

  test "SQLCipher 4, not 3 -- they write different file formats" do
    major = Vault::Library.cipher_version.to_s.split(".").first
    assert_equal "4", major, "saw #{Vault::Library.describe}"
  end
end
