module Vault
  # What the SQLite library underneath actually is.
  #
  # Two of the three facts here have already cost a day between them, so they are
  # asserted rather than assumed: the distribution package on Debian is SQLCipher
  # 3.4 (SQLite 3.15, below the 3.23 Active Record needs, and a different file
  # format), and a build of the SQLCipher sources without -DSQLITE_HAS_CODEC is
  # plain SQLite that accepts PRAGMA key and ignores it.
  module Library
    MINIMUM_SQLITE = "3.23.0".freeze

    module_function

    def cipher_version
      SQLite3::Database.new(":memory:").execute("PRAGMA cipher_version").flatten.first.presence
    rescue StandardError
      nil
    end

    def sqlite_version
      SQLite3::SQLITE_VERSION
    end

    def encrypting?
      cipher_version.present?
    end

    def usable?
      encrypting? && Gem::Version.new(sqlite_version) >= Gem::Version.new(MINIMUM_SQLITE)
    end

    def describe
      encrypting? ? "SQLCipher #{cipher_version} (SQLite #{sqlite_version})" : "plain SQLite #{sqlite_version}"
    end

    # libsodium, reached by rbnacl through FFI. It is loaded lazily — the first
    # call that needs it, which in this application is minting an identity. An
    # image without the shared library therefore starts, serves every page, and
    # fails at the single screen the operator cannot repeat.
    def sodium_available?
      require "rbnacl"
      RbNaCl::Random.random_bytes(8)
      true
    rescue LoadError, StandardError
      false
    end
  end
end
