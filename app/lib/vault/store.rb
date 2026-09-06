require "securerandom"
require "fileutils"

module Vault
  # Creating, opening, closing, re-keying and backing up the one file.
  #
  # WHERE THE SALT LIVES. SQLCipher writes a random 16-byte salt into the first
  # sixteen bytes of the database file and leaves them unencrypted, because it
  # needs them itself before any key exists. Those same sixteen bytes are the
  # Argon2id salt here. That is what makes "everything in one file" work without
  # a companion file for key-derivation material, and without the
  # cipher_plaintext_header_size trick — that pragma leaves the real SQLite
  # header in the clear, not free space for us, and it removes the salt from the
  # file instead of adding room.
  #
  # On create we generate the salt ourselves and hand SQLCipher the 48-byte key
  # form (32 key + 16 salt), so it stores our salt. On open we read those
  # sixteen bytes back, derive, and pass the same form again.
  class Store
    SALT_BYTES = 16
    FILENAME   = "dpp.db"

    class << self
      def data_dir
        Pathname.new(ENV.fetch("DPP_DATA_DIR", "/data"))
      end

      def path
        data_dir.join(ENV.fetch("DPP_DATABASE_FILENAME", FILENAME))
      end

      def exists?
        path.exist? && path.size >= SALT_BYTES
      end

      def stored_salt
        raise NotOpenError, "no vault at #{path}" unless exists?

        path.binread(SALT_BYTES)
      end

      # First run. Generates the salt, derives, connects, and brings the schema
      # up. Refuses rather than overwriting: the file is the user's only copy.
      def create!(passphrase)
        raise AlreadyExistsError, "a vault already exists at #{path}" if exists?

        FileUtils.mkdir_p(data_dir)
        salt = SecureRandom.random_bytes(SALT_BYTES)
        key  = Kdf.derive(passphrase, salt)

        Session.store(key: key, salt: salt, profile: Kdf::CURRENT_PROFILE)
        connect!
        migrate!
        true
      rescue StandardError
        close!
        raise
      end

      # Tries every KDF profile this application has ever shipped, newest first,
      # so a file written by an older version still opens.
      def open!(passphrase)
        raise NotOpenError, "no vault at #{path}" unless exists?

        salt = stored_salt

        Kdf.profiles_newest_first.each do |profile|
          key = Kdf.derive(passphrase, salt, profile: profile)
          Session.store(key: key, salt: salt, profile: profile)

          # A wrong key does not announce itself at connect time. SQLite defers
          # touching the file, so the first statement that reads a page is where
          # it fails — and that turns out to be one of the adapter's own pragmas,
          # before the probe below ever runs. Both have to be inside the rescue.
          begin
            connect!
            probe!
          rescue StandardError
            close!
            next
          end

          migrate!
          return true
        end

        raise LockedError, "the passphrase does not open this vault"
      end

      def open?
        Session.open? && ActiveRecord::Base.connection_pool.connected?
      rescue StandardError
        false
      end

      # remove_connection, not clear_all_connections!: clearing leaves the pool
      # in place with the configuration still on it, so the next stray query
      # quietly opens a fresh connection — and the adapter would then ask for a
      # key that is gone. Removing the pool means a query after locking fails as
      # what it is, "no connection", instead of surfacing as a key error from
      # somewhere deep in the adapter.
      def close!
        ActiveRecord::Base.remove_connection rescue nil
        Session.clear!
        true
      end

      # A consistent copy of the whole vault, taken while the application is
      # running. Copying the file with the filesystem is not equivalent: a write
      # in flight would be copied half-done.
      def backup!(destination)
        raise NotOpenError, "vault is not open" unless open?

        destination = Pathname.new(destination)
        raise ArgumentError, "#{destination} already exists" if destination.exist?

        ActiveRecord::Base.connection.execute("VACUUM INTO #{quote(destination.to_s)}")
        destination
      end

      # Re-keying by export rather than PRAGMA rekey: rekey rewrites every page
      # of the file in place, so an interruption leaves the user's only copy
      # half-encrypted with no way back. Exporting into a fresh file and moving
      # it over means the old file stays intact and readable until the new one
      # is complete on disk.
      def change_passphrase!(current_passphrase, new_passphrase)
        raise NotOpenError, "vault is not open" unless open?
        verify_passphrase!(current_passphrase)

        new_salt = SecureRandom.random_bytes(SALT_BYTES)
        new_key  = Kdf.derive(new_passphrase, new_salt)
        temp     = data_dir.join("#{path.basename}.rekey-#{SecureRandom.hex(4)}")

        connection = ActiveRecord::Base.connection
        connection.execute("ATTACH DATABASE #{quote(temp.to_s)} AS rekeyed KEY \"#{literal_for(new_key, new_salt)}\"")
        begin
          connection.execute("SELECT sqlcipher_export('rekeyed')")
        ensure
          connection.execute("DETACH DATABASE rekeyed")
        end

        # Everything is on disk before anything is replaced.
        File.open(temp, "rb") { |f| f.fsync }
        close!
        FileUtils.mv(temp.to_s, path.to_s)

        Session.store(key: new_key, salt: new_salt, profile: Kdf::CURRENT_PROFILE)
        connect!
        true
      rescue StandardError
        FileUtils.rm_f(temp.to_s) if temp
        raise
      end

      # Does this passphrase open the vault that is currently open? Used before
      # a re-key, so that a mistyped current passphrase is caught before the
      # file is touched.
      def verify_passphrase!(passphrase)
        candidate = Kdf.derive(passphrase, stored_salt, profile: Session.profile || Kdf::CURRENT_PROFILE)
        expected  = Session.pragma_key_literal
        actual    = literal_for(candidate, stored_salt)
        raise LockedError, "the passphrase does not open this vault" unless
          ActiveSupport::SecurityUtils.secure_compare(expected, actual)

        true
      end

      def database_config
        {
          "adapter"  => "sqlite3",
          "database" => path.to_s,
          "timeout"  => 5_000,
          # No WAL. WAL means a -wal and a -shm file beside the database, and the
          # requirement here is one file the user can copy. A single local writer
          # gains nothing from WAL anyway.
          "pragmas"  => { "journal_mode" => "delete", "synchronous" => "full", "foreign_keys" => true }
        }
      end

      private

      def connect!
        ActiveRecord::Base.establish_connection(database_config)
        ActiveRecord::Base.connection.verify!
      end

      # Reads a page. An encrypted file opened with the wrong key fails here and
      # not at connect time, because SQLite defers touching the file until it is
      # asked something.
      def probe!
        ActiveRecord::Base.connection.execute("SELECT count(*) FROM sqlite_master")
      end

      def migrate!
        context = ActiveRecord::MigrationContext.new(Rails.root.join("db/migrate"))
        context.migrate
      end

      def literal_for(key, salt)
        "x'#{key.unpack1('H*')}#{salt.unpack1('H*')}'"
      end

      def quote(string)
        "'#{string.gsub("'", "''")}'"
      end
    end
  end
end
