# Puts `PRAGMA key` in front of everything else on a new SQLite connection.
#
# It has to be the first statement on the connection: SQLCipher decides then
# whether the file is readable at all, and Rails' own pragmas (journal_mode,
# foreign_keys, synchronous) are ordinary statements that would fail first
# otherwise. Prepending configure_connection and running before `super` is the
# one place in the adapter's life cycle where that ordering is guaranteed.
#
# There is no maintained SQLCipher adapter for Active Record. This is the whole
# of what one would do.
module VaultPragmas
  # The failure this guards against is the quiet one. The sqlite3 gem builds and
  # runs happily against a library that came out of the SQLCipher source tree
  # without -DSQLITE_HAS_CODEC: `PRAGMA key` is accepted and ignored, and the
  # vault is written in the clear. Nothing else in the system notices. So the
  # first connection asks the library whether the codec is actually there, and
  # refuses to go on if it is not.
  def configure_connection
    unless VaultPragmas.codec_present?(@raw_connection)
      raise "This SQLite library has no SQLCipher codec: PRAGMA cipher_version " \
            "is empty, so PRAGMA key would be accepted and ignored and the vault " \
            "would be written unencrypted. Build the sqlite3 gem against " \
            "libsqlcipher (bundle config set build.sqlite3 --with-sqlcipher) and " \
            "make sure that library was compiled with -DSQLITE_HAS_CODEC."
    end

    literal = Vault::Session.pragma_key_literal
    @raw_connection.execute("PRAGMA key = \"#{literal}\"")
    super
  end

  def self.codec_present?(raw_connection)
    raw_connection.execute("PRAGMA cipher_version").flatten.first.present?
  rescue StandardError
    false
  end
end

ActiveSupport.on_load(:active_record_sqlite3adapter) do
  prepend VaultPragmas
end
