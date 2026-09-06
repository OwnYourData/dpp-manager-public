require "json"
require "base64"
require "securerandom"

module Did
  # The mandate an operator signs so that somebody else may hold their passport.
  #
  # This is the one statement in the whole system that only the operator can
  # make, and the reason this application exists in the shape it does: the DPP
  # Service stores passports at a custodian on the operator's behalf, and the
  # authority for that is not an account it holds but a signed sentence about
  # one passport, one custodian and one service. Nobody else can write it,
  # because nobody else has this key.
  #
  # What it says (docs/Delegation.md §5):
  #
  #   iss         us — and the custodian only accepts it if this DID is the
  #               controller it has recorded for the collection
  #   sub         the DPP Service that may redeem it, taken from that service's
  #               own discovery document rather than typed by hand
  #   aud         the custodian's base URL, so it cannot be presented elsewhere
  #   collection  the place in that custodian's store
  #   product_id  exactly one passport. No wildcard — that is what keeps the
  #               mandate bound to an object rather than to an account
  #   act         the operations it covers
  #   purpose     the purpose limitation of Art. 12(e) DGA; the custodian writes
  #               it into its event log
  #   nbf/exp     a window, so a forgotten mandate ends by itself
  #   jti         the handle the operator revokes it by
  #
  # Signed by hand rather than with the jwt gem, for two reasons that are not
  # style. The gem writes `"typ": "JWT"` into the header, and the whole point of
  # `typ` here is that a delegation cannot be replayed as a write token or as a
  # client assertion (RFC 8725 §3.11) — a wrong `typ` is refused. And the claim
  # set is serialised canonically: sorted keys, no insignificant whitespace,
  # ASCII only, which is what the conformance vectors pin down and what lets two
  # implementations produce the same signing input from the same claims.
  module Delegation
    ALGORITHM = "EdDSA".freeze
    TYP       = "dpp-delegation+jwt".freeze

    # D3: today the custodian accepts these three and refuses anything else,
    # fail-closed. `read` is deliberately reserved and not issued.
    ACT = %w[create update delete].freeze

    # The mandate covers everything the service will ever do with this passport,
    # because the alternative is signing again in the middle of an update. The
    # service can still only do those things to the one passport named here.
    PURPOSE = "dpp-hosting".freeze

    # 90 days, the custodian's maximum. Longer is refused on the way in, so
    # asking for more would only produce a mandate nobody accepts. It is also
    # the interval at which the operator has to reach for their key per
    # passport, which is why the application says when one is running out.
    LIFETIME = ENV.fetch("DPP_DELEGATION_LIFETIME", 90 * 86_400).to_i

    # Warn while there is still time to act. A mandate that has expired is not a
    # catastrophe — it is renewed with one signature — but a passport whose
    # mandate expired unnoticed cannot be updated or ended until somebody does.
    RENEW_WITHIN = 14 * 86_400

    class Error < StandardError; end

    Signed = Struct.new(:token, :claims, keyword_init: true) do
      def jti = claims["jti"]
      def expires_at = Time.at(claims["exp"]).utc
      def act = claims["act"]
    end

    module_function

    def issue(identity, audience:, collection:, product_id:, service_did:,
              act: ACT, lifetime: LIFETIME, now: Time.now.to_i)
      raise Error, "there is no identity to sign the mandate with" if identity.nil?
      raise Error, "the custodian has no address" if audience.to_s.strip.empty?
      raise Error, "the custodian names no collection" if collection.to_s.strip.empty?
      raise Error, "the passport has no product identifier" if product_id.to_s.strip.empty?
      raise Error, "the service publishes no DID to delegate to" if service_did.to_s.strip.empty?

      claims = {
        "iss"        => identity.did,
        "sub"        => service_did.to_s,
        # Without the trailing slash, because that is how the custodian
        # normalises its own base URL before comparing.
        "aud"        => audience.to_s.strip.chomp("/"),
        "collection" => collection.to_s.strip,
        "product_id" => product_id.to_s,
        "act"        => Array(act).map(&:to_s),
        "purpose"    => PURPOSE,
        "iat"        => now,
        "nbf"        => now,
        "exp"        => now + lifetime.to_i,
        "jti"        => SecureRandom.hex(8)
      }

      Signed.new(token: sign(identity, claims), claims: claims)
    end

    # The claims of a mandate without checking anything. For showing back what
    # was signed and for comparing our record with the service's — never for a
    # decision, which is why it is called peek and not verify.
    def peek(token)
      payload = token.to_s.split(".")[1]
      return nil if payload.nil?

      JSON.parse(decode64(payload))
    rescue JSON::ParserError, ArgumentError
      nil
    end

    def sign(identity, claims)
      header = { "alg" => ALGORITHM, "typ" => TYP, "kid" => "#{identity.did}#key-doc" }
      signing_input = "#{encode64(canonical(header))}.#{encode64(canonical(claims))}"

      key = Oyd.signing_key(identity.document_key)
      "#{signing_input}.#{encode64(key.sign(signing_input))}"
    end

    # JSON with sorted keys and no insignificant whitespace — the serialisation
    # both sides of this protocol have to agree on, byte for byte.
    #
    # Non-ASCII is refused rather than escaped: Ruby writes it raw and other
    # languages escape it by default, and the two signing inputs would then
    # differ in a way that is invisible in a diff of the claims. Every claim
    # here is an identifier, a URL or a number, so this costs nothing today and
    # turns a silent signature mismatch into an exception if that ever changes.
    def canonical(object)
      json = JSON.generate(deep_sort(object))
      raise Error, "non-ASCII in a signed claim" unless json.ascii_only?

      json
    end

    def deep_sort(object)
      case object
      when Hash  then object.keys.map(&:to_s).sort.to_h { |key| [ key, deep_sort(object[key]) ] }
      when Array then object.map { |entry| deep_sort(entry) }
      else object
      end
    end

    def encode64(raw) = Base64.urlsafe_encode64(raw, padding: false)

    def decode64(text) = Base64.urlsafe_decode64(text + ("=" * ((4 - (text.length % 4)) % 4)))
  end
end
