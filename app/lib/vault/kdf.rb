require "argon2"

module Vault
  # Turns a passphrase into the 32-byte key SQLCipher is opened with.
  #
  # Argon2id rather than SQLCipher's own PBKDF2: the passphrase is the only
  # secret in the system, it is chosen by a person, and memory-hardness is what
  # makes guessing it expensive on hardware the attacker owns.
  #
  # The parameters are NOT stored in the file. They cannot be — see
  # Vault::Store for where the salt lives and why there is no room beside it.
  # Instead every profile this application has ever shipped stays listed here,
  # and opening tries them newest first. A file written by an older version
  # therefore keeps opening, and Store#profile_in_use reports which one answered
  # so the user can be offered a re-key.
  module Kdf
    # m_cost is in KiB, as libargon2 takes it. 64 MiB / t=3 / p=4 lands around
    # half a second on an office machine, which is the target: long enough to
    # hurt a guessing attack, short enough that unlocking does not feel broken.
    PROFILES = {
      1 => { t_cost: 3, m_cost_kib: 65_536, parallelism: 4 }
    }.freeze

    CURRENT_PROFILE = 1
    KEY_BYTES = 32

    # Newest first: the profile a file was written with is usually the newest
    # one that existed when it was created, so the first try is nearly always
    # the right one.
    def self.profiles_newest_first
      PROFILES.keys.sort.reverse
    end

    def self.derive(passphrase, salt, profile: CURRENT_PROFILE)
      params = PROFILES.fetch(profile) { raise ArgumentError, "unknown KDF profile #{profile.inspect}" }

      pwd  = passphrase.to_s.dup.force_encoding(Encoding::BINARY)
      salt = salt.to_s.dup.force_encoding(Encoding::BINARY)

      out = FFI::MemoryPointer.new(:char, KEY_BYTES)
      pwd_ptr  = FFI::MemoryPointer.new(:char, pwd.bytesize).put_bytes(0, pwd)
      salt_ptr = FFI::MemoryPointer.new(:char, salt.bytesize).put_bytes(0, salt)

      result = Argon2::Ext.argon2id_hash_raw(
        params[:t_cost], params[:m_cost_kib], params[:parallelism],
        pwd_ptr, pwd.bytesize, salt_ptr, salt.bytesize, out, KEY_BYTES
      )
      raise "Argon2id failed with code #{result}" unless result.zero?

      out.read_bytes(KEY_BYTES)
    ensure
      # Best effort: overwrite the copies we made before they are collected.
      pwd_ptr&.put_bytes(0, "\0" * pwd.bytesize) if pwd
      out&.put_bytes(0, "\0" * KEY_BYTES)
    end
  end
end
