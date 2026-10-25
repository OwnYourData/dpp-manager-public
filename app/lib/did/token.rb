require "securerandom"
require "digest"
require "base64"

module Did
  # The bearer token the DPP Service wants on every write.
  #
  # There is no registration and no client secret anywhere in this: the operator
  # issues the token themselves and signs it with the document key of their own
  # DID. The service resolves that DID, takes the public key out of the document
  # and checks the signature. Revoking the DID therefore ends every token it ever
  # signed, without a revocation list existing anywhere.
  #
  # The contract is narrow and every part of it has been got wrong before:
  #
  #   alg  EdDSA          — and jwt needs jwt/eddsa loaded, or it does not know it
  #   kid  <did>#key-doc
  #   iss  == sub == the DID, WITHOUT the "@<repository>" suffix: the service
  #                    normalises its own identifiers but resolves iss verbatim
  #   aud  the service's public base URL
  #   exp  at most 900 seconds out (DID_AUTH_MAX_LIFETIME)
  #   jti  fresh for every token: the service accepts each one once
  #   rqh  the request the token is for (below)
  #
  # Signed with the DOCUMENT key — slot 0 of the DID's key field, not slot 1.
  #
  # The token of a write names the one request it is made for, in the claim
  # `rqh` (dpp-service docs/Integrity.md section 11):
  #
  #   rqh = base64url(SHA-256(METHOD "\n" TARGET "\n" base64url(SHA-256(BODY))))
  #
  # METHOD in capitals, TARGET the path with the query exactly as it goes on
  # the wire, BODY the bytes sent; base64url without padding. With it the token
  # is the operator's signed statement that they asked for exactly this change,
  # and the service keeps it as such. A token over another body, path or method
  # is refused. So the token is minted where the request is built, by Bearer.
  module Token
    # The service refuses anything longer. Staying well under it costs nothing:
    # a token is minted per request, not per session.
    MAX_LIFETIME = 900
    DEFAULT_LIFETIME = 300

    CLAIM = "rqh".freeze

    # What the controllers hand to DppService::Client in place of a token: who
    # signs and for which service. The client calls +token_for+ once it has
    # built the request, with the method, the request-target and the body it is
    # about to send, and gets a token minted for exactly that request.
    Bearer = Struct.new(:identity, :audience) do
      def token_for(method, target, body)
        Token.issue(identity, audience: audience, request: [ method, target, body ])
      end
    end

    module_function

    def bearer(identity, audience:)
      raise ArgumentError, "audience is required" if audience.blank?

      Bearer.new(identity, audience)
    end

    # +request+ is [method, target, body]; without it the token names no
    # request, which the service accepts on reads only.
    def issue(identity, audience:, lifetime: DEFAULT_LIFETIME, request: nil)
      require "jwt"
      require "jwt/eddsa"

      raise ArgumentError, "audience is required" if audience.blank?

      seconds = [ lifetime.to_i, MAX_LIFETIME ].min
      now = Time.now.to_i
      did = identity.did

      claims = { "iss" => did, "sub" => did, "aud" => audience.to_s,
                 "iat" => now, "exp" => now + seconds, "jti" => SecureRandom.hex(8) }
      claims[CLAIM] = request_hash(*request) if request

      JWT.encode(claims, Oyd.signing_key(identity.document_key), "EdDSA", { "kid" => "#{did}#key-doc" })
    end

    def request_hash(method, target, body)
      input = [ method.to_s.upcase, target.to_s, b64(Digest::SHA256.digest(body.to_s.b)) ].join("\n")
      b64(Digest::SHA256.digest(input.b))
    end

    def b64(bytes) = Base64.urlsafe_encode64(bytes, padding: false)

    # Sign a token and verify it against the key the VDR publishes for this DID.
    #
    # This is what the setup wizard offers as "check my keys": it exercises the
    # whole chain the service will walk — key material, encoding, resolution —
    # without writing anything anywhere and without needing the service to be
    # reachable at all.
    def self_test(identity, audience: "https://example.invalid")
      require "jwt"
      require "jwt/eddsa"

      token = issue(identity, audience: audience, lifetime: 60)
      public_key = Oyd.public_key(identity.did)
      verify_key = ::Ed25519::VerifyKey.new(public_key)

      JWT.decode(token, verify_key, true,
                 algorithm: "EdDSA", aud: audience, verify_aud: true,
                 iss: identity.did, verify_iss: true,
                 required_claims: %w[iss sub aud exp])
      true
    end
  end
end
