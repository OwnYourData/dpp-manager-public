require "digest"
require "securerandom"

module Vault
  # Holds the derived key for as long as the vault is open — in process memory
  # and nowhere else.
  #
  # Not in the session cookie, not in a file, not in an environment variable.
  #
  # An open vault belongs to the browser session that opened it. Opening it
  # hands that session a random token (`bind!`); the session keeps the token in
  # its cookie, and this holder keeps only its SHA-256 digest. A request may use
  # the vault only when its token matches (`held_by?`). Every other session sees
  # the vault as locked, even while it is open — which matters as soon as the
  # application is reachable by more than one browser, for instance behind a
  # reverse proxy. Typing the passphrase in another session takes the vault over:
  # a new token replaces the old one, and the first session is locked out from
  # its next request on.
  #
  # The time of the holder's last request is kept here too, rather than in its
  # cookie, so that the idle limit can be enforced by whichever request arrives
  # first — not only by the holder coming back.
  #
  # Nothing expensive happens under the mutex: deriving a key and the delay after
  # a wrong passphrase run outside it, so a stream of wrong guesses from another
  # session never holds up the requests of the session that has the vault.
  #
  # One process, one worker, one user — a module-level holder behind a mutex is
  # the honest shape for that. If this ever grows to several workers, this class
  # is the thing that has to change, and it will be obvious.
  class Session
    TOKEN_BYTES = 32

    @mutex         = Mutex.new
    @key           = nil
    @salt          = nil
    @profile       = nil
    @opened_at     = nil
    @holder_digest = nil
    @last_seen_at  = nil

    class << self
      def open?
        @mutex.synchronize { !@key.nil? }
      end

      # Replaces the key material. The binding to a session is left as it is, so
      # that re-keying the open vault does not lock out the session doing it.
      def store(key:, salt:, profile:)
        @mutex.synchronize do
          wipe!
          @key       = key.dup.force_encoding(Encoding::BINARY)
          @salt      = salt.dup.force_encoding(Encoding::BINARY)
          @profile   = profile
          @opened_at = Time.current
        end
      end

      def profile
        @mutex.synchronize { @profile }
      end

      def opened_at
        @mutex.synchronize { @opened_at }
      end

      # What a passphrase has to be derived with to be compared against the key
      # that is held: the salt and the KDF profile. nil while nothing is open.
      def derivation_inputs
        @mutex.synchronize { @key.nil? ? nil : [ @salt.dup, @profile ] }
      end

      # Binds the open vault to a new session and returns the token that session
      # carries. Whoever held it before no longer does.
      def bind!
        token = SecureRandom.urlsafe_base64(TOKEN_BYTES)
        @mutex.synchronize do
          raise NotOpenError, "vault is not open" if @key.nil?

          @holder_digest = digest(token)
          @last_seen_at  = Time.current
        end
        token
      end

      # The same, but only if +candidate+ is the key that is held — the check and
      # the binding under one lock, so that nothing can change in between. The
      # candidate is derived by the caller, outside the lock. nil when it does
      # not match or nothing is open.
      def bind_if_key!(candidate)
        token = SecureRandom.urlsafe_base64(TOKEN_BYTES)
        @mutex.synchronize do
          return nil if @key.nil? || candidate.nil?
          return nil unless candidate.bytesize == @key.bytesize &&
                            ActiveSupport::SecurityUtils.secure_compare(candidate.b, @key)

          @holder_digest = digest(token)
          @last_seen_at  = Time.current
        end
        token
      end

      # Does the session carrying +token+ hold the open vault?
      def held_by?(token)
        return false if token.blank?

        presented = digest(token.to_s)
        @mutex.synchronize do
          next false if @key.nil? || @holder_digest.nil?

          ActiveSupport::SecurityUtils.secure_compare(presented, @holder_digest)
        end
      end

      # The holder did something. Called only for requests of the holding
      # session; nobody else keeps the vault open.
      def touch!
        @mutex.synchronize { @last_seen_at = Time.current unless @key.nil? }
      end

      def last_seen_at
        @mutex.synchronize { @last_seen_at }
      end

      # Has the holder been away longer than +limit+?
      def idle_longer_than?(limit)
        @mutex.synchronize do
          next false if @key.nil? || @last_seen_at.nil?

          Time.current - @last_seen_at > limit
        end
      end

      # The literal SQLCipher expects: 32 key bytes and 16 salt bytes as one hex
      # string. Passing the salt explicitly rather than letting SQLCipher read it
      # from the file keeps creating and opening on the same code path.
      def pragma_key_literal
        @mutex.synchronize do
          raise NotOpenError, "vault is not open" if @key.nil?

          "x'#{@key.unpack1('H*')}#{@salt.unpack1('H*')}'"
        end
      end

      def clear!
        @mutex.synchronize do
          wipe!
          @key = @salt = @profile = @opened_at = nil
          @holder_digest = @last_seen_at = nil
        end
      end

      private

      def digest(token) = Digest::SHA256.digest(token)

      # Best effort under a garbage-collected runtime: overwrite the bytes we can
      # still reach. Ruby may have moved copies around, so this narrows the
      # window rather than closing it. Documented, not oversold. Caller holds the
      # mutex.
      def wipe!
        @key&.replace("\0" * @key.bytesize) rescue nil
        @salt&.replace("\0" * @salt.bytesize) rescue nil
      end
    end
  end
end
