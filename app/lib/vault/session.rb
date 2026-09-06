module Vault
  # Holds the derived key for as long as the vault is open — in process memory
  # and nowhere else.
  #
  # Not in the session cookie, not in a file, not in an environment variable.
  # The cookie carries a session id and nothing more; whoever holds the cookie
  # can use an already-open vault, which is what a logged-in user is, but the
  # cookie alone opens nothing after the process ends.
  #
  # One process, one worker, one user — a module-level holder behind a mutex is
  # the honest shape for that. If this ever grows to several workers, this class
  # is the thing that has to change, and it will be obvious.
  class Session
    @mutex     = Mutex.new
    @key       = nil
    @salt      = nil
    @profile   = nil
    @opened_at = nil

    class << self
      def open?
        @mutex.synchronize { !@key.nil? }
      end

      def store(key:, salt:, profile:)
        @mutex.synchronize do
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
          # Best effort under a garbage-collected runtime: overwrite the bytes we
          # can still reach. Ruby may have moved copies around, so this narrows
          # the window rather than closing it. Documented, not oversold.
          @key&.replace("\0" * @key.bytesize) rescue nil
          @salt&.replace("\0" * @salt.bytesize) rescue nil
          @key = @salt = @profile = @opened_at = nil
        end
      end
    end
  end
end
